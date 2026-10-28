// Agent CDP from the browser host straight to this Chromium Host
// (plans/cmux-next/chrome-parity/p01-process.md).
//
// The browser host (cmux-tui/crates/cmux-browser-host, provider_link/
// direct_relay.rs) drives agent sessions on cmux's Chromium tabs over raw
// DevTools. In host mode those tabs run here, so the host opens its own
// provider link to the browser host and relays the raw messages of the tabs
// it is told to, and cmux's main thread never sees them. Chrome's remote
// debugging pipe does the same job (content/browser/devtools/
// devtools_pipe_handler.cc): the pipe is read and written on threads of its
// own, and only the dispatch to the page's DevTools session runs on the
// browser process's UI thread.
//
// Credential: cmux sends kOpProviderLink with the provider socket, the relay
// credential it derived from the daemon-minted provider secret (HMAC-SHA256,
// ProviderSecret::relay_credential in provider.rs), the link id cmux names
// this host by when it tells the browser host a page is ready, and the pids
// the socket's peer may be. The secret itself never reaches this process. The
// op is not in the generated table: it is versioned on its own (as
// kOpEnergySaver).
//   i32 version (kProviderLinkVersion), then version 1's fields:
//   str socket (NULL: no link), str credential, str link id, i32 host pid,
//   i32 listener pid
// A host that serves the op lists kProviderLinkHelloName in its HELLO.
//
// Provider link frames (provider.rs `Frame`): a big-endian u32 length, then
// that many bytes of JSON tagged by "t".
//   -> relay.hello {version, link, credential}  <- relay.hello.ack {}
//   <- relay.attach {targetId, browser}         <- relay.detach {targetId}
//   <> cdp {targetId, message}                  -> relay.closed {targetId, reason}
// `browser` is cmux's id of the tab's page. Replies with an id at or above
// kDirectFirstRawId are the link's; other raw replies stay cmux's (its own
// relay counts up from 2^30), and protocol events go to the link while the
// page is relayed, and to cmux too when cmux watches the page itself.
//
// Plain C++, no CEF: scripts/cmux-next/tests/chromium-host-dispatch.test.sh
// builds it on Linux. AgentRelays is UI thread only, like host_dispatch.h.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "chromium_host_tlv.h"
#include "devtools_message_id.h"

namespace cmux_host {

// Next to kOpEnergySaver (host_energy_saver.h): not in the generated op table.
inline constexpr uint16_t kOpProviderLink = 0x800c;
inline constexpr int32_t kProviderLinkVersion = 1;
// The name a host that serves kOpProviderLink lists in its HELLO's exports.
inline constexpr char kProviderLinkHelloName[] = "cmux_host_provider_link";
// provider.rs RELAY_VERSION.
inline constexpr int32_t kRelayVersion = 1;
// direct_relay.rs DIRECT_FIRST_RAW_ID: 3 x 2^29.
inline constexpr long long kDirectFirstRawId = 3LL << 29;
// provider.rs MAX_FRAME_BYTES.
inline constexpr size_t kMaxRelayFrame = size_t{64} << 20;

// kOpProviderLink's fields.
struct ProviderLinkConfig {
  std::optional<std::string> socket;  // nullopt: end the link
  std::string credential;
  std::string link_id;
  int32_t host_pid = 0;
  int32_t listener_pid = 0;

  bool operator==(const ProviderLinkConfig& other) const = default;
};

// Writes kOpProviderLink's fields (the remote shim's side).
inline void WriteProviderLink(const ProviderLinkConfig& config, control::TlvWriter* w) {
  w->I32(kProviderLinkVersion);
  w->Str(config.socket ? config.socket->c_str() : nullptr);
  w->Str(config.credential.c_str());
  w->Str(config.link_id.c_str());
  w->I32(config.host_pid);
  w->I32(config.listener_pid);
}

// The op's fields; nullopt for a malformed op (no version or one below 1,
// wrong types, version 1 with more fields, a socket with no credential or
// link id).
inline std::optional<ProviderLinkConfig> DecodeProviderLink(const std::vector<control::Field>& fields) {
  control::TlvReader r(fields);
  const int32_t version = r.I32();
  ProviderLinkConfig config;
  config.socket = r.Str();
  const std::optional<std::string> credential = r.Str();
  const std::optional<std::string> link_id = r.Str();
  config.host_pid = r.I32();
  config.listener_pid = r.I32();
  if (!r.ok() || version < 1 || !credential || !link_id) return std::nullopt;
  if (version == kProviderLinkVersion && !r.AtEnd()) return std::nullopt;
  if (config.socket && (config.socket->empty() || credential->empty() || link_id->empty())) return std::nullopt;
  config.credential = *credential;
  config.link_id = *link_id;
  return config;
}

namespace relay_json {

inline void AppendString(std::string* out, std::string_view text) {
  static constexpr char kHex[] = "0123456789abcdef";
  out->push_back('"');
  for (const char c : text) {
    const auto byte = static_cast<unsigned char>(c);
    switch (c) {
      case '"': out->append("\\\""); break;
      case '\\': out->append("\\\\"); break;
      case '\n': out->append("\\n"); break;
      case '\r': out->append("\\r"); break;
      case '\t': out->append("\\t"); break;
      default:
        if (byte < 0x20) {
          out->append("\\u00");
          out->push_back(kHex[byte >> 4]);
          out->push_back(kHex[byte & 0xf]);
        } else {
          out->push_back(c);
        }
    }
  }
  out->push_back('"');
}

inline void AppendUtf8(std::string* out, uint32_t code) {
  if (code < 0x80) {
    out->push_back(static_cast<char>(code));
  } else if (code < 0x800) {
    out->push_back(static_cast<char>(0xc0 | (code >> 6)));
    out->push_back(static_cast<char>(0x80 | (code & 0x3f)));
  } else if (code < 0x10000) {
    out->push_back(static_cast<char>(0xe0 | (code >> 12)));
    out->push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3f)));
    out->push_back(static_cast<char>(0x80 | (code & 0x3f)));
  } else {
    out->push_back(static_cast<char>(0xf0 | (code >> 18)));
    out->push_back(static_cast<char>(0x80 | ((code >> 12) & 0x3f)));
    out->push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3f)));
    out->push_back(static_cast<char>(0x80 | (code & 0x3f)));
  }
}

inline bool Hex4(std::string_view p, size_t i, uint32_t* out) {
  if (i + 4 > p.size()) return false;
  uint32_t value = 0;
  for (size_t k = i; k < i + 4; ++k) {
    const char c = p[k];
    value <<= 4;
    if (c >= '0' && c <= '9') {
      value |= static_cast<uint32_t>(c - '0');
    } else if (c >= 'a' && c <= 'f') {
      value |= static_cast<uint32_t>(c - 'a' + 10);
    } else if (c >= 'A' && c <= 'F') {
      value |= static_cast<uint32_t>(c - 'A' + 10);
    } else {
      return false;
    }
  }
  *out = value;
  return true;
}

// The string starting at p[i] ('"'), unescaped; the index after it in *end.
// A lone surrogate becomes U+FFFD, as serde_json's lossy reads do.
inline std::optional<std::string> ReadString(std::string_view p, size_t i, size_t* end) {
  std::string out;
  for (++i; i < p.size(); ++i) {
    const char c = p[i];
    if (c == '"') {
      *end = i + 1;
      return out;
    }
    if (c != '\\') {
      out.push_back(c);
      continue;
    }
    if (++i >= p.size()) return std::nullopt;
    switch (p[i]) {
      case '"': out.push_back('"'); break;
      case '\\': out.push_back('\\'); break;
      case '/': out.push_back('/'); break;
      case 'b': out.push_back('\b'); break;
      case 'f': out.push_back('\f'); break;
      case 'n': out.push_back('\n'); break;
      case 'r': out.push_back('\r'); break;
      case 't': out.push_back('\t'); break;
      case 'u': {
        uint32_t code = 0;
        if (!Hex4(p, i + 1, &code)) return std::nullopt;
        i += 4;
        if (code >= 0xd800 && code < 0xdc00) {
          uint32_t low = 0;
          if (i + 2 < p.size() && p[i + 1] == '\\' && p[i + 2] == 'u' && Hex4(p, i + 3, &low) && low >= 0xdc00 &&
              low < 0xe000) {
            code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
            i += 6;
          } else {
            code = 0xfffd;
          }
        } else if (code >= 0xdc00 && code < 0xe000) {
          code = 0xfffd;
        }
        AppendUtf8(&out, code);
        break;
      }
      default:
        return std::nullopt;
    }
  }
  return std::nullopt;
}

// The top-level string and integer fields of one JSON object; other values
// are skipped. nullopt when it is not one well-formed object.
struct Flat {
  std::unordered_map<std::string, std::string> strings;
  std::unordered_map<std::string, long long> integers;
};

inline std::optional<Flat> ReadFlat(std::string_view p) {
  using namespace cmux_shim::devtools_id_detail;
  const char* d = p.data();
  const size_t n = p.size();
  Flat flat;
  size_t i = SkipSpace(d, n, 0);
  if (i >= n || d[i] != '{') return std::nullopt;
  i = SkipSpace(d, n, i + 1);
  if (i < n && d[i] == '}') return SkipSpace(d, n, i + 1) == n ? std::optional<Flat>(flat) : std::nullopt;
  // One member per pass, up to its ',' or the object's '}': every pass consumes input.
  bool more = true;
  while (more) {
    if (i >= n || d[i] != '"') return std::nullopt;
    size_t key_end = 0;
    std::optional<std::string> key = ReadString(p, i, &key_end);
    if (!key) return std::nullopt;
    i = SkipSpace(d, n, key_end);
    if (i >= n || d[i] != ':') return std::nullopt;
    i = SkipSpace(d, n, i + 1);
    if (i < n && d[i] == '"') {
      size_t value_end = 0;
      std::optional<std::string> value = ReadString(p, i, &value_end);
      if (!value) return std::nullopt;
      flat.strings[*key] = std::move(*value);
      i = value_end;
    } else {
      const size_t start = i;
      i = SkipValue(d, n, i);
      if (i > n) return std::nullopt;
      const std::string_view token = p.substr(start, i - start);
      bool integer = !token.empty() && token.size() <= 19;
      long long value = 0;
      bool negative = false;
      for (size_t k = 0; k < token.size() && integer; ++k) {
        if (k == 0 && token[k] == '-') {
          negative = true;
          integer = token.size() > 1;
        } else if (token[k] >= '0' && token[k] <= '9') {
          value = value * 10 + (token[k] - '0');
        } else {
          integer = false;
        }
      }
      if (integer) flat.integers[*key] = negative ? -value : value;
    }
    i = SkipSpace(d, n, i);
    if (i >= n || (d[i] != '}' && d[i] != ',')) return std::nullopt;
    more = d[i] == ',';
    if (more) i = SkipSpace(d, n, i + 1);
  }
  if (SkipSpace(d, n, i + 1) != n) return std::nullopt;
  return flat;
}

}  // namespace relay_json

// One frame from the browser host on the link.
struct RelayFrame {
  enum class Kind { kHelloAck, kAttach, kDetach, kCdp, kOther };
  Kind kind = Kind::kOther;
  std::string target;
  int32_t browser = 0;
  std::string message;
};

// The frame's JSON body; nullopt for a malformed one (not an object, no
// "t", or a known tag without its fields).
inline std::optional<RelayFrame> DecodeRelayFrame(std::string_view json) {
  std::optional<relay_json::Flat> flat = relay_json::ReadFlat(json);
  if (!flat) return std::nullopt;
  auto tag = flat->strings.find("t");
  if (tag == flat->strings.end()) return std::nullopt;
  RelayFrame frame;
  auto target = flat->strings.find("targetId");
  if (target != flat->strings.end()) frame.target = target->second;
  const bool has_target = target != flat->strings.end() && !target->second.empty();
  if (tag->second == "relay.hello.ack") {
    frame.kind = RelayFrame::Kind::kHelloAck;
  } else if (tag->second == "relay.attach") {
    auto browser = flat->integers.find("browser");
    if (!has_target || browser == flat->integers.end() || browser->second <= 0 || browser->second > INT32_MAX) {
      return std::nullopt;
    }
    frame.kind = RelayFrame::Kind::kAttach;
    frame.browser = static_cast<int32_t>(browser->second);
  } else if (tag->second == "relay.detach") {
    if (!has_target) return std::nullopt;
    frame.kind = RelayFrame::Kind::kDetach;
  } else if (tag->second == "cdp") {
    auto message = flat->strings.find("message");
    if (!has_target || message == flat->strings.end()) return std::nullopt;
    frame.kind = RelayFrame::Kind::kCdp;
    frame.message = std::move(message->second);
  }
  return frame;
}

inline std::string EncodeRelayHello(std::string_view link_id, std::string_view credential) {
  std::string out = "{\"t\":\"relay.hello\",\"version\":" + std::to_string(kRelayVersion) + ",\"link\":";
  relay_json::AppendString(&out, link_id);
  out.append(",\"credential\":");
  relay_json::AppendString(&out, credential);
  out.push_back('}');
  return out;
}

inline std::string EncodeRelayCdp(std::string_view target, std::string_view message) {
  std::string out = "{\"t\":\"cdp\",\"targetId\":";
  relay_json::AppendString(&out, target);
  out.append(",\"message\":");
  relay_json::AppendString(&out, message);
  out.push_back('}');
  return out;
}

inline std::string EncodeRelayClosed(std::string_view target, std::string_view reason) {
  std::string out = "{\"t\":\"relay.closed\",\"targetId\":";
  relay_json::AppendString(&out, target);
  out.append(",\"reason\":");
  relay_json::AppendString(&out, reason);
  out.push_back('}');
  return out;
}

// A CDP error reply to `command` with `text`, as Chromium answers a message
// it cannot dispatch (DevToolsSession::DispatchProtocolMessage,
// content/browser/devtools/devtools_session.cc); nullopt for a command
// without an integer id, which no caller waits on.
inline std::optional<std::string> DevToolsErrorReply(std::string_view command, std::string_view text) {
  std::optional<relay_json::Flat> flat = relay_json::ReadFlat(command);
  if (!flat) return std::nullopt;
  auto id = flat->integers.find("id");
  if (id == flat->integers.end()) return std::nullopt;
  std::string out = "{\"id\":" + std::to_string(id->second) + ",\"error\":{\"code\":-32000,\"message\":";
  relay_json::AppendString(&out, text);
  out.push_back('}');
  if (auto session = flat->strings.find("sessionId"); session != flat->strings.end()) {
    out.append(",\"sessionId\":");
    relay_json::AppendString(&out, session->second);
  }
  out.push_back('}');
  return out;
}

// One frame's bytes on the link: the big-endian length, then the JSON.
inline std::string RelayFrameBytes(std::string_view json) {
  std::string out;
  const auto length = static_cast<uint32_t>(json.size());
  out.push_back(static_cast<char>(length >> 24));
  out.push_back(static_cast<char>(length >> 16));
  out.push_back(static_cast<char>(length >> 8));
  out.push_back(static_cast<char>(length));
  out.append(json);
  return out;
}

// The tabs the link relays, on the UI thread: the link's frames in, each
// page's raw DevTools out. Chromium's calls come in as functions so the
// tests run it without CEF.
class AgentRelays {
 public:
  struct Calls {
    // cmux's browser id to Chromium's (HostContext::Browser).
    std::function<int(int32_t)> chromium_of;
    // cmux_shim_devtools_send and cmux_shim_devtools_watch_events.
    std::function<int(int, const char*)> send;
    std::function<void(int, int)> watch;
    // A frame's JSON to the link (ProviderLink::Write: never blocks).
    std::function<void(std::string)> write;
  };

  explicit AgentRelays(Calls calls) : calls_(std::move(calls)) {}

  // A frame from the link.
  void OnFrame(const RelayFrame& frame) {
    switch (frame.kind) {
      case RelayFrame::Kind::kAttach:
        return Attach(frame.target, frame.browser);
      case RelayFrame::Kind::kDetach:
        return Detach(frame.target);
      case RelayFrame::Kind::kCdp:
        return Send(frame.target, frame.message);
      case RelayFrame::Kind::kHelloAck:
      case RelayFrame::Kind::kOther:
        return;
    }
  }

  // A raw DevTools message of cmux's browser `client` (CMUX_SHIM_DEVTOOLS_EVENT):
  // true when it is the link's alone, so cmux never gets it.
  bool TakeDevToolsMessage(int32_t client, std::string_view json) {
    auto relayed = target_of_.find(client);
    if (relayed == target_of_.end()) return false;
    long long id = 0;
    switch (cmux_shim::TopLevelDevToolsId(json.data(), json.size(), &id)) {
      case cmux_shim::DevToolsIdKind::kInt:
        if (id < kDirectFirstRawId) return false;  // a reply of cmux's own relay
        Write(relayed->second, json);
        return true;
      case cmux_shim::DevToolsIdKind::kNone:
        Write(relayed->second, json);
        return cmux_watched_.count(client) == 0;
      case cmux_shim::DevToolsIdKind::kInvalid:
        return false;
    }
    return false;
  }

  // cmux's own kOpDevtoolsWatchEvents for `client`: the watch Chromium gets
  // (on while the link relays the page, whatever cmux asked).
  int CmuxWatch(int32_t client, bool enabled) {
    if (enabled) {
      cmux_watched_.insert(client);
    } else {
      cmux_watched_.erase(client);
    }
    return enabled || target_of_.count(client) ? 1 : 0;
  }

  // The page of `client` closed (CMUX_SHIM_BEFORE_CLOSE).
  void BrowserClosed(int32_t client) {
    cmux_watched_.erase(client);
    auto relayed = target_of_.find(client);
    if (relayed == target_of_.end()) return;
    calls_.write(EncodeRelayClosed(relayed->second, "the tab's page closed"));
    client_of_.erase(relayed->second);
    target_of_.erase(relayed);
  }

  // The link ended: no page is relayed, and each gets cmux's watch back.
  void LinkEnded() {
    const std::unordered_map<int32_t, std::string> relayed = std::move(target_of_);
    target_of_.clear();
    client_of_.clear();
    for (const auto& [client, target] : relayed) RestoreWatch(client);
  }

  size_t relayed() const { return target_of_.size(); }
  bool Relays(int32_t client) const { return target_of_.count(client) > 0; }

 private:
  void Attach(const std::string& target, int32_t client) {
    if (auto older = client_of_.find(target); older != client_of_.end() && older->second != client) {
      const int32_t previous = older->second;
      target_of_.erase(previous);
      client_of_.erase(older);
      RestoreWatch(previous);
    }
    if (auto other = target_of_.find(client); other != target_of_.end() && other->second != target) {
      client_of_.erase(other->second);
    }
    client_of_[target] = client;
    target_of_[client] = target;
    calls_.watch(calls_.chromium_of(client), 1);
  }

  void Detach(const std::string& target) {
    auto relayed = client_of_.find(target);
    if (relayed == client_of_.end()) return;
    const int32_t client = relayed->second;
    client_of_.erase(relayed);
    target_of_.erase(client);
    RestoreWatch(client);
  }

  void Send(const std::string& target, const std::string& message) {
    auto relayed = client_of_.find(target);
    const char* refusal = nullptr;
    if (relayed == client_of_.end()) {
      refusal = "the tab is not attached on the Chromium Host's relay link";
    } else {
      switch (calls_.send(calls_.chromium_of(relayed->second), message.c_str())) {
        case 1:
          return;
        case 0:
          refusal = "the tab's page has no browser";
          break;
        default:
          refusal = "Chromium refused the message";
          break;
      }
    }
    if (std::optional<std::string> reply = DevToolsErrorReply(message, refusal)) Write(target, *reply);
  }

  void RestoreWatch(int32_t client) { calls_.watch(calls_.chromium_of(client), cmux_watched_.count(client) ? 1 : 0); }

  void Write(const std::string& target, std::string_view message) { calls_.write(EncodeRelayCdp(target, message)); }

  Calls calls_;
  std::unordered_map<int32_t, std::string> target_of_;  // by cmux's browser id
  std::unordered_map<std::string, int32_t> client_of_;  // by the browser host's target id
  std::unordered_set<int32_t> cmux_watched_;            // pages cmux watches itself
};

// The peer process of a connected Unix socket (0 when unknown), and whether
// `config` accepts it as the browser host (host_provider_link.mm).
int32_t ProviderLinkPeerPid(int fd);
bool ProviderLinkAcceptsPeer(const ProviderLinkConfig& config, int32_t peer);

// Whether the peer of a connected Unix socket is code signed as this cmux,
// named by its audit token (never by pid): with a Team ID, the peer satisfies
// this build's Team ID requirement; an unsigned build's peer runs an
// executable of this app bundle (host_peer_identity.mm, macOS; p01-process.md
// risk 6). The link's reader calls it before relay.hello.
bool ProviderLinkPeerSignedAsCmux(int fd);

// The socket to the browser host and its two threads (host_provider_link.mm).
// Connect, Close and the callbacks are UI thread only; Write is any thread
// and never blocks. `post_main` runs a task on the UI thread (PostToMain);
// `on_frames` gets each batch the reader read, `on_end` runs once when the
// link that Connect started ends by itself (not after Close or a newer
// Connect). `peer_signed` checks the dialed socket's peer on the reader
// thread, after the pid rule and before the credential leaves
// (ProviderLinkPeerSignedAsCmux). The object must outlive the UI thread's tasks.
class ProviderLink {
 public:
  using Post = std::function<void(std::function<void()>)>;
  using OnFrames = std::function<void(std::vector<RelayFrame>)>;
  using OnEnd = std::function<void()>;
  using PeerSigned = std::function<bool(int fd)>;

  ProviderLink(Post post_main, OnFrames on_frames, OnEnd on_end, PeerSigned peer_signed);
  ~ProviderLink();
  ProviderLink(const ProviderLink&) = delete;
  ProviderLink& operator=(const ProviderLink&) = delete;

  // Ends the current link and dials `config`'s socket (none: stays down);
  // nothing when the link runs or dials for `config` already (Dials).
  void Connect(const ProviderLinkConfig& config);
  bool Dials(const ProviderLinkConfig& config) const;
  void Close();
  void Write(std::string json);
  // relay.hello.ack came and the link has not ended.
  bool connected() const;

 private:
  struct Session;
  static void ReadLoop(ProviderLink* link, std::shared_ptr<Session> session, ProviderLinkConfig dial, Post post,
                       PeerSigned peer_signed);
  static void WriteLoop(std::shared_ptr<Session> session);
  static bool NextOutbound(Session& session, std::string* bytes);
  void Drain(uint64_t generation);
  void Ended(uint64_t generation);

  Post post_main_;
  OnFrames on_frames_;
  OnEnd on_end_;
  PeerSigned peer_signed_;
  std::shared_ptr<Session> session_;
  ProviderLinkConfig config_;  // the last Connect's
  uint64_t generation_ = 0;
};

}  // namespace cmux_host
