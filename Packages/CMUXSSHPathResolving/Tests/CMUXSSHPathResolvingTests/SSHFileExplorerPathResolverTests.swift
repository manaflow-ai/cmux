import XCTest
import Foundation
import CMUXSSHPathResolving

final class SSHFileExplorerPathResolverTests: XCTestCase {

    deinit {}

    // MARK: - remoteHomePath(from:)

    func testRemoteHomePath_typicalUserAtHost() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "imgyu@100.79.206.23"),
            "/home/imgyu"
        )
    }

    func testRemoteHomePath_userAtHostWithPort() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "ubuntu@host:2222"),
            "/home/ubuntu"
        )
    }

    func testRemoteHomePath_root() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "root@host"),
            "/root"
        )
    }

    func testRemoteHomePath_rootWithIPv6() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "root@[::1]:22"),
            "/root"
        )
    }

    func testRemoteHomePath_userWithIPv6() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "user@[fd00::1]:22"),
            "/home/user"
        )
    }

    func testRemoteHomePath_userPreservesCase() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "Imgyu@host"),
            "/home/Imgyu"
        )
    }

    func testRemoteHomePath_dashedUser() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "build-bot@ci.example.com"),
            "/home/build-bot"
        )
    }

    func testRemoteHomePath_userWithDot() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "first.last@host"),
            "/home/first.last"
        )
    }

    func testRemoteHomePath_trimsSurroundingWhitespace() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "  imgyu@host  "),
            "/home/imgyu"
        )
    }

    func testRemoteHomePath_nilDestination() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: nil),
            ""
        )
    }

    func testRemoteHomePath_emptyDestination() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: ""),
            ""
        )
    }

    func testRemoteHomePath_whitespaceOnlyDestination() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "   "),
            ""
        )
    }

    func testRemoteHomePath_destinationWithoutAtSign() {
        // No `@` means we cannot reliably extract a user — must NOT guess.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "justhostname"),
            ""
        )
    }

    func testRemoteHomePath_destinationStartingWithAtSign() {
        // Empty user portion is malformed.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "@host"),
            ""
        )
    }

    func testRemoteHomePath_destinationEndingWithAtSign() {
        // Empty host portion is malformed.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "user@"),
            ""
        )
    }

    func testRemoteHomePath_doubleAtSignTakesFirst() {
        // First `@` separates user from host. Anything after lives on host.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "imgyu@nested@host"),
            "/home/imgyu"
        )
    }

    // MARK: - effectiveRootPath(workspaceDirectory:remoteHomePath:)

    func testEffectiveRootPath_macUsersPathFallsBackToHome() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/Users/imgyukim/Downloads",
                remoteHomePath: "/home/imgyu"
            ),
            "/home/imgyu"
        )
    }

    func testEffectiveRootPath_macVolumesPathFallsBackToHome() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/Volumes/Backup/projects",
                remoteHomePath: "/home/imgyu"
            ),
            "/home/imgyu"
        )
    }

    func testEffectiveRootPath_alreadyRemoteHomePathIsPreserved() {
        // If the workspace cwd already lives under remote home, keep it.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/home/imgyu/projects/foo",
                remoteHomePath: "/home/imgyu"
            ),
            "/home/imgyu/projects/foo"
        )
    }

    func testEffectiveRootPath_nonMacLinuxStylePathIsPreserved() {
        // /etc/foo is plausible on remote — don't override.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/etc/nginx",
                remoteHomePath: "/home/imgyu"
            ),
            "/etc/nginx"
        )
    }

    func testEffectiveRootPath_rootSlashIsPreserved() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/",
                remoteHomePath: "/home/imgyu"
            ),
            "/"
        )
    }

    func testEffectiveRootPath_privatePathIsPreserved() {
        // `/private/...` is not in `isMacLocalPath`'s prefix allowlist, so the
        // resolver does not redirect it. Pinned so the deliberate narrowness
        // of the allowlist (only `/Users/`, `/Volumes/`) stays explicit.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/private/etc",
                remoteHomePath: "/home/imgyu"
            ),
            "/private/etc"
        )
    }

    func testEffectiveRootPath_emptyHomeDoesNotFallback() {
        // Without a credible remote home, leave the workspace cwd alone so
        // we don't replace a Mac path with "" (file explorer would die).
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/Users/imgyukim/Downloads",
                remoteHomePath: ""
            ),
            "/Users/imgyukim/Downloads"
        )
    }

    func testEffectiveRootPath_emptyDirIsPreservedWhenHomeEmpty() {
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "",
                remoteHomePath: ""
            ),
            ""
        )
    }

    func testEffectiveRootPath_emptyDirIsPreservedEvenWhenHomeKnown() {
        // Empty workspace directory is preserved verbatim — `isMacLocalPath("")`
        // is false, so the resolver does not substitute the home. Callers
        // (FileExplorerStore) treat an empty `rootPath` as "no root selected"
        // and skip loading, which is the safe default. Pinned so any future
        // change to substitute the home here has to be intentional.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "",
                remoteHomePath: "/home/imgyu"
            ),
            ""
        )
    }

    // MARK: - isMacLocalPath

    func testIsMacLocalPath_users() {
        XCTAssertTrue(SSHFileExplorerPathResolver.isMacLocalPath("/Users/x"))
        XCTAssertTrue(SSHFileExplorerPathResolver.isMacLocalPath("/Users/imgyukim/workspace"))
    }

    func testIsMacLocalPath_volumes() {
        XCTAssertTrue(SSHFileExplorerPathResolver.isMacLocalPath("/Volumes/Foo"))
    }

    func testIsMacLocalPath_homeIsNotMacLocal() {
        // /home/<user> exists on Linux remotes; do not treat as Mac-only.
        XCTAssertFalse(SSHFileExplorerPathResolver.isMacLocalPath("/home/imgyu"))
    }

    func testIsMacLocalPath_rootSlash() {
        XCTAssertFalse(SSHFileExplorerPathResolver.isMacLocalPath("/"))
    }

    func testIsMacLocalPath_caseSensitive() {
        // /users/... (lowercase) is not a real macOS root — keep it false.
        XCTAssertFalse(SSHFileExplorerPathResolver.isMacLocalPath("/users/x"))
    }

    // MARK: - End-to-end (composition)

    func testComposition_macWorkspaceWithSSHRemote_routesToRemoteHome() {
        // Workspace cwd captured from a Mac caller, SSH-bound to `user@host`:
        // the file explorer must anchor at the remote home, not the Mac path
        // (which is unreachable on the Linux remote).
        let home = SSHFileExplorerPathResolver.remoteHomePath(from: "imgyu@100.79.206.23")
        let root = SSHFileExplorerPathResolver.effectiveRootPath(
            workspaceDirectory: "/Users/imgyukim/Downloads",
            remoteHomePath: home
        )
        XCTAssertEqual(home, "/home/imgyu")
        XCTAssertEqual(root, "/home/imgyu")
    }

    func testComposition_rootSSH_routesToSlashRoot() {
        let home = SSHFileExplorerPathResolver.remoteHomePath(from: "root@server")
        let root = SSHFileExplorerPathResolver.effectiveRootPath(
            workspaceDirectory: "/Users/imgyukim/projects",
            remoteHomePath: home
        )
        XCTAssertEqual(home, "/root")
        XCTAssertEqual(root, "/root")
    }

    func testComposition_remoteWorkspaceCwdAlreadyMatchesHome_isPreserved() {
        // When a workspace's cwd was somehow already a remote-style path
        // (e.g., the user manually set it), keep it — don't override.
        let home = SSHFileExplorerPathResolver.remoteHomePath(from: "imgyu@host")
        let root = SSHFileExplorerPathResolver.effectiveRootPath(
            workspaceDirectory: "/home/imgyu/projects/cmux",
            remoteHomePath: home
        )
        XCTAssertEqual(root, "/home/imgyu/projects/cmux")
    }

    // MARK: - Concurrency / nonisolated invocation
    //
    // The three helpers are marked `nonisolated`. These tests document that
    // they can be invoked from a detached Task — i.e. off the main actor —
    // and produce the same results as on-actor calls. The runtime XCTAssert
    // exercises the call shape; the bigger value is that the test bodies
    // make the off-main-actor invocation path part of the project's
    // executable contract, so a Swift 6 default actor isolation rollout
    // can't silently turn these into main-actor-only helpers without
    // someone adjusting these test sites first.

    func testRemoteHomePath_isCallableFromDetachedTask() async {
        let result = await Task.detached {
            SSHFileExplorerPathResolver.remoteHomePath(from: "imgyu@host")
        }.value
        XCTAssertEqual(result, "/home/imgyu")
    }

    func testEffectiveRootPath_isCallableFromDetachedTask() async {
        let result = await Task.detached {
            SSHFileExplorerPathResolver.effectiveRootPath(
                workspaceDirectory: "/Users/imgyukim/Downloads",
                remoteHomePath: "/home/imgyu"
            )
        }.value
        XCTAssertEqual(result, "/home/imgyu")
    }

    func testIsMacLocalPath_isCallableFromDetachedTask() async {
        let result = await Task.detached {
            SSHFileExplorerPathResolver.isMacLocalPath("/Users/x")
        }.value
        XCTAssertTrue(result)
    }

    // MARK: - isMacLocalPath boundary

    func testIsMacLocalPath_exactUsersWithoutTrailingSlashIsNotMacLocal() {
        // Prefix is `/Users/` (with the trailing slash), so the exact path
        // `/Users` does not match. This pins the behavior so a future
        // "let's also catch the bare directory" tweak has to reckon with
        // the SSH side-effect: rerouting `/Users` itself on a Mac-local
        // workspace would be an unrelated regression.
        XCTAssertFalse(SSHFileExplorerPathResolver.isMacLocalPath("/Users"))
    }

    func testIsMacLocalPath_exactVolumesWithoutTrailingSlashIsNotMacLocal() {
        XCTAssertFalse(SSHFileExplorerPathResolver.isMacLocalPath("/Volumes"))
    }

    func testIsMacLocalPath_usersWithTrailingSlashOnlyIsMacLocal() {
        // `/Users/` (just the trailing slash, no child) DOES match the
        // prefix. Document the edge so anyone reading the implementation
        // knows it was deliberate, not an oversight.
        XCTAssertTrue(SSHFileExplorerPathResolver.isMacLocalPath("/Users/"))
    }

    // MARK: - remoteHomePath additional parsing edges

    func testRemoteHomePath_userTokenInternalSpaceIsPreserved() {
        // Outer whitespace gets trimmed, but spaces inside the user token
        // are kept verbatim. POSIX usernames typically don't contain spaces,
        // so this is rarely a real scenario — the test exists to fail loudly
        // if someone adds an over-eager sanitization step that silently
        // mutates user-supplied destinations.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: " im gyu@host "),
            "/home/im gyu"
        )
    }

    func testRemoteHomePath_userTokenSurroundingTabsAreTrimmed() {
        // `.whitespacesAndNewlines` covers tabs too. Lock in the contract.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "\timgyu\t@host"),
            "/home/imgyu"
        )
    }

    func testRemoteHomePath_unicodeUserPreservesNonASCII() {
        // Non-ASCII usernames (CJK in this case) must round-trip into
        // /home/<user> unchanged. Path encoding is the consumer's job, not
        // ours; we just preserve what the user typed.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "임규@host"),
            "/home/임규"
        )
    }

    func testRemoteHomePath_userWithColonSyntaxKeepsColon() {
        // Splitting on the first `@` keeps any colon attached to the user
        // token; the resolver does not attempt port extraction from the user
        // portion. Pinned so a future "smart port re-parse" can't silently
        // change the resolved home path.
        XCTAssertEqual(
            SSHFileExplorerPathResolver.remoteHomePath(from: "imgyu:2222@host"),
            "/home/imgyu:2222"
        )
    }
}
