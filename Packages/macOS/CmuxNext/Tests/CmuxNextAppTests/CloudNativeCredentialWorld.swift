import CmuxNextDaemon

actor CloudNativeCredentialWorld {
    private var scope = String(repeating: "a", count: 64)
    private var socket: String?
    private var changeWhileStarting = false
    private(set) var ensures: [String] = []
    func changeDuringStartup() { changeWhileStarting = true }
    func session() -> CloudCredentialRelay.Session {
        .init(signedIn: true, team: "team_test", scope: scope, requiresScope: true,
              nativeLink: CloudCredentialNativeLink(scope: scope, socket: socket))
    }
    func ensure(_ expected: String) {
        ensures.append(expected)
        if changeWhileStarting { scope = String(repeating: "b", count: 64) }
        socket = "/tmp/owned-native.sock"
    }
}
