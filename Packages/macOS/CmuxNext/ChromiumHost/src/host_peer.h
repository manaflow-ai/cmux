// The adoption socket's peer check on macOS (host_peer_mac.mm, task
// p01-process-150; host_adoption.h's Listener::CheckPeer).
#pragma once

#include <sys/types.h>

#include <optional>
#include <string>

namespace cmux_host {

// The pid of the process at the other end of the connected Unix socket `fd`
// when it is this user's, its code (by audit token) satisfies the designated
// requirement of the app bundle at `app_bundle` (the host's --main-bundle) and
// is signed by the host's own team; nullopt otherwise, and always for a host
// with no team. Asks securityd: never on the UI thread.
std::optional<pid_t> TrustedPeer(int fd, const std::string& app_bundle);

}  // namespace cmux_host
