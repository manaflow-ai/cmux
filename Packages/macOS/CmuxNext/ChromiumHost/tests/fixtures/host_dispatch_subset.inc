// A subset of generated/host_dispatch.inc for host_dispatch_test.cpp: the
// ops host_dispatch.mm names, cut from gen-chromium-host-wire.py's output
// for the current header (same ids, same case bodies), so the dispatcher's
// ordering, id maps and bounds are tested without CEF or the generator.

namespace cmux_host {
enum Op : uint16_t {
  kOpForkApiVersion = 3,
  kOpSetNewTabPageUrl = 23,
  kOpInitialize = 26,
  kOpCreateWindow = 28,
  kOpTabAdd = 29,
  kOpTabDuplicate = 30,
  kOpLoadUrl = 35,
  kOpSetFocus = 40,
  kOpSetFocusRequestHandler = 41,
  kOpDevtoolsCall = 51,
  kOpTabNavigationState = 65,
  kOpLiveBrowserCount = 97,
  kOpShutdown = 99,
};
inline constexpr uint16_t kOpEvent = 0x8001;
inline constexpr uint16_t kOpReply = 0x8002;
inline constexpr uint16_t kOpMirror = 0x8003;
inline constexpr uint16_t kOpAck = 0x8004;

void InstallPolicySetFocusRequestHandler(HostContext& ctx, bool installed);
void InstallPolicySetUnhandledKeyHandler(HostContext& ctx, bool installed);
void InstallPolicyDevtoolsSetKeyHandler(HostContext& ctx, bool installed);
void InstallPolicySetWindowRequestHandler(HostContext& ctx, bool installed);

inline bool DispatchOp(HostContext& ctx, uint16_t op, uint32_t token, TlvReader& r) {
  switch (op) {
    case kOpSetNewTabPageUrl: {
      const std::optional<std::string> url = r.Str();
      if (!r.ok() || !r.AtEnd()) return false;
      cmux_shim_set_new_tab_page_url(url ? url->c_str() : nullptr);
      ctx.Ack(token);
      return true;
    }
    case kOpCreateWindow: {
      const int32_t minted = r.I32();
      const auto request = r.I32();
      void* const parent_view = ctx.PageView(r.View());
      const auto width = r.I32();
      const auto height = r.I32();
      const std::optional<std::string> url = r.Str();
      const std::optional<std::string> profile_cache_path = r.Str();
      if (!r.ok() || !r.AtEnd()) return false;
      const int result = cmux_shim_create_window(request, parent_view, width, height, url ? url->c_str() : nullptr, profile_cache_path ? profile_cache_path->c_str() : nullptr);
      ctx.BindMinted(kOpCreateWindow, minted, result);
      ctx.Ack(token);
      return true;
    }
    case kOpTabAdd: {
      const int32_t minted = r.I32();
      const auto window_browser_id = r.I32();
      const std::optional<std::string> url = r.Str();
      const auto index = r.I32();
      const auto activate = r.I32();
      if (!r.ok() || !r.AtEnd()) return false;
      const int result = cmux_shim_tab_add(ctx.Browser(window_browser_id), url ? url->c_str() : nullptr, index, activate);
      ctx.BindMinted(kOpTabAdd, minted, result);
      ctx.Ack(token);
      return true;
    }
    case kOpLoadUrl: {
      const auto browser_id = r.I32();
      const std::optional<std::string> url = r.Str();
      if (!r.ok() || !r.AtEnd()) return false;
      cmux_shim_load_url(ctx.Browser(browser_id), url ? url->c_str() : nullptr);
      ctx.Ack(token);
      return true;
    }
    case kOpSetFocus: {
      const auto browser_id = r.I32();
      const auto focus = r.I32();
      if (!r.ok() || !r.AtEnd()) return false;
      cmux_shim_set_focus(ctx.Browser(browser_id), focus);
      ctx.Ack(token);
      return true;
    }
    case kOpSetFocusRequestHandler: {
      const bool installed = r.I32() != 0;
      if (!r.ok() || !r.AtEnd()) return false;
      InstallPolicySetFocusRequestHandler(ctx, installed);
      ctx.Ack(token);
      return true;
    }
    case kOpDevtoolsCall: {
      const int32_t minted = r.I32();
      const auto browser_id = r.I32();
      const std::optional<std::string> method = r.Str();
      const std::optional<std::string> params_json = r.Str();
      if (!r.ok() || !r.AtEnd()) return false;
      const int result = cmux_shim_devtools_call(ctx.Browser(browser_id), method ? method->c_str() : nullptr, params_json ? params_json->c_str() : nullptr);
      ctx.BindMinted(kOpDevtoolsCall, minted, result);
      ctx.Ack(token);
      return true;
    }
    case kOpShutdown: {
      if (!r.ok() || !r.AtEnd()) return false;
      cmux_shim_shutdown();
      ctx.Ack(token);
      return true;
    }
    default:
      return false;  // a mirror, local or unknown op never arrives
  }
}

inline bool ProduceMirror(HostContext& ctx, uint16_t op, TlvReader& r) {
  switch (op) {
    case kOpForkApiVersion: {
      if (!r.ok() || !r.AtEnd()) return false;
      const auto result = cmux_shim_fork_api_version();
      TlvWriter key;
      TlvWriter value;
      value.I32(result);
      ctx.PushMirror(kOpForkApiVersion, key, value);
      return true;
    }
    case kOpTabNavigationState: {
      const auto browser_id = r.I32();
      if (!r.ok() || !r.AtEnd()) return false;
      const auto result = cmux_shim_tab_navigation_state(ctx.Browser(browser_id));
      TlvWriter key;
      key.I32(browser_id);
      TlvWriter value;
      value.Str(result);
      cmux_shim_free(result);
      ctx.PushMirror(kOpTabNavigationState, key, value);
      return true;
    }
    case kOpLiveBrowserCount: {
      if (!r.ok() || !r.AtEnd()) return false;
      const auto result = cmux_shim_live_browser_count();
      TlvWriter key;
      TlvWriter value;
      value.I32(result);
      ctx.PushMirror(kOpLiveBrowserCount, key, value);
      return true;
    }
    default:
      return false;
  }
}

struct MirrorRefresh {
  int kind;
  int request;
  uint16_t op;
};
inline constexpr int kEventAttach = 0;  // pseudo event
inline constexpr MirrorRefresh kMirrorRefreshes[] = {
    {0, -1, kOpForkApiVersion},  // attach
    {2, -1, kOpTabNavigationState},  // CMUX_SHIM_AFTER_CREATED
    {8, -1, kOpTabNavigationState},  // CMUX_SHIM_LOAD_START
    {3, -1, kOpTabNavigationState},  // CMUX_SHIM_BEFORE_CLOSE
    {0, -1, kOpLiveBrowserCount},  // attach
    {2, -1, kOpLiveBrowserCount},  // CMUX_SHIM_AFTER_CREATED
    {3, -1, kOpLiveBrowserCount},  // CMUX_SHIM_BEFORE_CLOSE
};

template <typename F>
inline void ForEachMirrorRefreshedBy(int kind, int request, F&& f) {
  for (const MirrorRefresh& row : kMirrorRefreshes) {
    if (row.op != 0 && row.kind == kind && (row.request < 0 || row.request == request)) f(row.op);
  }
}

inline void EncodeEvent(TlvWriter& w, int kind, int browser_id, int request, int64_t a, int64_t b,
                        const char* s1, const char* s2) {
  w.I32(kind);
  w.I32(browser_id);
  w.I32(request);
  w.I64(a);
  w.I64(b);
  w.Str(s1);
  w.Str(s2);
}
}  // namespace cmux_host
