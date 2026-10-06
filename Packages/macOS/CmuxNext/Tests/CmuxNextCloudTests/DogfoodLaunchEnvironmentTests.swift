@testable import CmuxNextCloud
import Foundation
import Testing

/// A tagged build launched with `CMUX_AUTH_CREDENTIALS_FILE` signs in with that
/// file, not with the machine's ~/.secrets/cmuxterm-dev.env: main strips
/// inherited CMUX_* variables (LaunchIdentity) before CloudAuth reads them, so
/// the auth launch keys are captured first and given to CloudAuth only
/// (2026-10-06: a pairing on cmux-lawrence-2 signed in as the machine's account).
@Suite struct DogfoodLaunchEnvironmentTests {
    @Test func theAuthLaunchKeysAreKeptAndNothingElse() {
        let launch = CloudAuth.launchAuthKeys(from: [
            "CMUX_AUTH_CREDENTIALS_FILE": "/tmp/creds.env", "CMUX_DEV_AUTH_PROFILE": "personal",
            "CMUX_DEV_AUTH_REPLACE_SESSION": "1", "CMUX_DEV_AUTH_ACCOUNT": "e@x", "CMUX_DOGFOOD_STACK_EMAIL": "e@x", "CMUX_DOGFOOD_STACK_PASSWORD": "p",
            "CMUX_SOCKET_PATH": "/tmp/other.sock", "CMUX_TAG": "other", "HOME": "/h",
        ])
        #expect(Set(launch.keys) == ["CMUX_AUTH_CREDENTIALS_FILE", "CMUX_DEV_AUTH_PROFILE", "CMUX_DEV_AUTH_ACCOUNT", "CMUX_DEV_AUTH_REPLACE_SESSION",
                                      "CMUX_DOGFOOD_STACK_EMAIL", "CMUX_DOGFOOD_STACK_PASSWORD"])
    }

    @Test func aCredentialsFileStrippedFromTheProcessStillWins() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-creds-\(UUID().uuidString).env")
        try "CMUX_DOGFOOD_STACK_EMAIL=lawrence@x\nCMUX_DOGFOOD_STACK_PASSWORD=lp\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: file) }
        let machine = ["/h/.secrets/cmuxterm-dev.env": "CMUX_DOGFOOD_STACK_EMAIL=machine@x\nCMUX_DOGFOOD_STACK_PASSWORD=mp\n"]
        let read: (String) -> String? = { machine[$0] ?? (try? String(contentsOfFile: $0, encoding: .utf8)) }
        // The process environment after LaunchIdentity.stripInheritedEnvironment: the key is gone.
        let stripped = ["HOME": "/h"]
        let launch = CloudAuth.launchAuthKeys(from: ["CMUX_AUTH_CREDENTIALS_FILE": file.path, "HOME": "/h"])
        let environment = CloudAuth.authEnvironment(process: stripped, launch: launch)
        #expect(DogfoodCredentials.resolve(environment: environment, home: "/h", read: read) == DogfoodCredentials(email: "lawrence@x", password: "lp"))
        // Without the captured launch keys the machine's account would sign in (the bug).
        #expect(DogfoodCredentials.resolve(environment: stripped, home: "/h", read: read) == DogfoodCredentials(email: "machine@x", password: "mp"))
    }

    @Test func aValueTheProcessStillHasIsNotOverridden() {
        let environment = CloudAuth.authEnvironment(process: ["CMUX_DEV_AUTH_PROFILE": "agent"], launch: ["CMUX_DEV_AUTH_PROFILE": "personal"])
        #expect(environment["CMUX_DEV_AUTH_PROFILE"] == "agent")
    }
}
