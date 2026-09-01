import Foundation
import Testing
@testable import CmuxCLISocketAuth

/// Regression coverage for the CLI socket credential boundary.
///
/// A connection has two distinct credential demands: an initial request, which
/// must remain credential-free until the server challenges it, and an explicit
/// authentication challenge. Keeping those demands separate prevents a
/// successful allow-all request from touching LocalAuthentication.
@Suite(.serialized)
struct SocketCredentialResolverTests {
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }
    }

    private func resolver(
        explicit: String? = nil,
        environmentPassword: String? = nil,
        filePassword: String? = nil,
        keychainPassword: String? = nil,
        fileCounter: CallCounter = CallCounter(),
        keychainCounter: CallCounter = CallCounter()
    ) -> SocketCredentialResolver {
        var environment: [String: String] = [:]
        if let environmentPassword {
            environment["CMUX_SOCKET_PASSWORD"] = environmentPassword
        }
        return SocketCredentialResolver(
            explicitPassword: explicit,
            socketPath: "/tmp/cmux-debug-credential-test.sock",
            environment: environment,
            filePasswordProvider: {
                fileCounter.increment()
                return filePassword
            },
            keychainPasswordProvider: { _ in
                keychainCounter.increment()
                return keychainPassword
            }
        )
    }

    @Test
    func explicitPasswordWinsWithoutReadingDeferredSources() {
        let fileCounter = CallCounter()
        let keychainCounter = CallCounter()
        let resolver = resolver(
            explicit: "flag-password",
            environmentPassword: "environment-password",
            filePassword: "file-password",
            keychainPassword: "keychain-password",
            fileCounter: fileCounter,
            keychainCounter: keychainCounter
        )

        #expect(resolver.password(for: .initialConnection) == "flag-password")
        #expect(resolver.password(for: .authenticationRequired) == "flag-password")
        #expect(fileCounter.value == 0)
        #expect(keychainCounter.value == 0)
        #expect(resolver.source == .explicit)
    }

    @Test
    func environmentPasswordWinsWithoutReadingDeferredSources() {
        let fileCounter = CallCounter()
        let keychainCounter = CallCounter()
        let resolver = resolver(
            environmentPassword: "environment-password",
            filePassword: "file-password",
            keychainPassword: "keychain-password",
            fileCounter: fileCounter,
            keychainCounter: keychainCounter
        )

        #expect(resolver.password(for: .initialConnection) == "environment-password")
        #expect(resolver.password(for: .authenticationRequired) == "environment-password")
        #expect(fileCounter.value == 0)
        #expect(keychainCounter.value == 0)
        #expect(resolver.source == .environment)
    }

    @Test
    func filePasswordIsReadOnlyAfterAuthenticationChallengeAndCached() {
        let fileCounter = CallCounter()
        let keychainCounter = CallCounter()
        let resolver = resolver(
            filePassword: "file-password",
            keychainPassword: "keychain-password",
            fileCounter: fileCounter,
            keychainCounter: keychainCounter
        )

        #expect(resolver.password(for: .initialConnection) == nil)
        #expect(fileCounter.value == 0)
        #expect(keychainCounter.value == 0)

        #expect(resolver.password(for: .authenticationRequired) == "file-password")
        #expect(resolver.password(for: .authenticationRequired) == "file-password")
        #expect(fileCounter.value == 1)
        #expect(keychainCounter.value == 0)
        #expect(resolver.source == .file)
    }

    @Test
    func keychainProviderIsDemandDrivenAndInvokedAtMostOnce() {
        let fileCounter = CallCounter()
        let keychainCounter = CallCounter()
        let resolver = resolver(
            filePassword: nil,
            keychainPassword: "keychain-password",
            fileCounter: fileCounter,
            keychainCounter: keychainCounter
        )

        #expect(resolver.password(for: .initialConnection) == nil)
        #expect(keychainCounter.value == 0)

        #expect(resolver.password(for: .authenticationRequired) == "keychain-password")
        #expect(resolver.password(for: .authenticationRequired) == "keychain-password")
        #expect(fileCounter.value == 1)
        #expect(keychainCounter.value == 1)
        #expect(resolver.source == .keychain)
    }

    @Test
    func concurrentAuthenticationDemandsShareOneResolution() {
        let keychainCounter = CallCounter()
        let resolver = resolver(
            keychainPassword: "keychain-password",
            keychainCounter: keychainCounter
        )

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            _ = resolver.password(for: .authenticationRequired)
        }

        #expect(keychainCounter.value == 1)
    }

    @Test
    func expiredAuthenticationDeadlineDoesNotStartDeferredSources() {
        let fileCounter = CallCounter()
        let keychainCounter = CallCounter()
        let resolver = resolver(
            filePassword: "file-password",
            keychainPassword: "keychain-password",
            fileCounter: fileCounter,
            keychainCounter: keychainCounter
        )

        #expect(
            resolver.password(
                for: .authenticationRequired,
                deadline: Date(timeIntervalSince1970: 0)
            ) == nil
        )
        #expect(fileCounter.value == 0)
        #expect(keychainCounter.value == 0)
    }

    @Test
    func socketPathScopeWinsOverMismatchedEnvironmentTag() {
        let services = SocketCredentialResolver.keychainServices(
            socketPath: "/tmp/cmux-debug-target.tag.sock",
            environment: ["CMUX_TAG": "different-tag"]
        )

        #expect(
            services == [
                "com.cmuxterm.app.socket-control.target-tag",
                "com.cmuxterm.app.socket-control",
            ]
        )
    }

    @Test
    func explicitResolverInputsAreNotReusedAcrossSecrets() {
        let session = SocketCredentialResolutionSession(environment: [:])
        let first = session.resolver(
            explicitPassword: "first-password",
            socketPath: "/tmp/cmux.sock"
        )
        let second = session.resolver(
            explicitPassword: "second-password",
            socketPath: "/tmp/cmux.sock"
        )

        #expect(first !== second)
        #expect(second.immediatePassword == "second-password")
    }

    @Test
    func implicitRoutesPartitionDeferredKeychainLookupsByScope() {
        let keychainCounter = CallCounter()
        let session = SocketCredentialResolutionSession(
            environment: [:],
            filePasswordProvider: { nil },
            keychainPasswordProvider: { _ in
                keychainCounter.increment()
                return "keychain-password"
            }
        )
        let first = session.resolver(
            explicitPassword: nil,
            socketPath: "/tmp/cmux-debug-first.sock"
        )
        let second = session.resolver(
            explicitPassword: nil,
            socketPath: "/tmp/cmux-debug-second.sock"
        )

        #expect(first !== second)
        #expect(
            session.resolver(
                explicitPassword: nil,
                socketPath: "/tmp/cmux-debug-first.sock"
            ) === first
        )
        #expect(first.authenticationModeCoordinator !== second.authenticationModeCoordinator)
        #expect(first.password(for: .authenticationRequired) == "keychain-password")
        #expect(first.password(for: .authenticationRequired) == "keychain-password")
        #expect(second.password(for: .authenticationRequired) == "keychain-password")
        #expect(keychainCounter.value == 2)
    }

    @Test
    func authenticationModeCoordinatorAllowsOneProbeAndPublishesMode() {
        let coordinator = SocketAuthenticationModeCoordinator()

        #expect(coordinator.current == .unknown)
        #expect(coordinator.claimProbe())
        #expect(!coordinator.claimProbe())
        coordinator.recordCredentialFree()

        #expect(coordinator.current == .credentialFree)
        #expect(!coordinator.claimProbe())
        coordinator.recordPasswordRequired()
        #expect(coordinator.current == .passwordRequired)
    }

    @Test
    func failedProbeDisablesFutureBlockingProbes() {
        let coordinator = SocketAuthenticationModeCoordinator()

        #expect(coordinator.claimProbe())
        coordinator.recordProbeFailure()

        #expect(coordinator.current == .probeFailed)
        #expect(!coordinator.claimProbe())
    }

    @Test
    func initialConnectionLeavesDeferredProvidersUntouched() {
        let fileCounter = CallCounter()
        let keychainCounter = CallCounter()
        let resolver = resolver(
            filePassword: "file-password",
            keychainPassword: "keychain-password",
            fileCounter: fileCounter,
            keychainCounter: keychainCounter
        )

        #expect(!SocketAuthenticationChallenge.isRequired("PONG"))
        #expect(resolver.password(for: .initialConnection) == nil)
        #expect(fileCounter.value == 0)
        #expect(keychainCounter.value == 0)
    }

    @Test
    func plainTextCloudSignInMessageIsNotSocketChallenge() {
        #expect(
            !SocketAuthenticationChallenge.isRequired(
                "ERROR: Cloud VM access requires sign-in. Send auth <password> first"
            )
        )
    }

    @Test
    func allowAllResponsesNeverDemandCredentials() {
        #expect(!SocketAuthenticationChallenge.isRequired("PONG"))
        #expect(!SocketAuthenticationChallenge.isRequired(#"{"id":"1","ok":true,"result":{}}"#))
        #expect(SocketAuthenticationChallenge.isRequired("ERROR: Authentication required — send auth <password> first"))
        #expect(!SocketAuthenticationChallenge.isRequired("ERROR: Cloud VM access requires sign-in"))
        #expect(
            SocketAuthenticationChallenge.isRequired(
                #"{"id":"1","ok":false,"error":{"code":"auth_required","message":"Authentication required. Send auth <password> first."}}"#
            )
        )
        #expect(
            !SocketAuthenticationChallenge.isRequired(
                #"{"id":"1","ok":false,"error":{"code":"auth_required"}}"#
            )
        )
        #expect(
            !SocketAuthenticationChallenge.isRequired(
                #"{"id":"1","ok":false,"error":{"code":"auth_required","message":"Cloud VM access requires sign-in. Run `cmux auth login`, then retry."}}"#
            )
        )
    }

    @Test
    func onlyPositiveResponsesEstablishCredentialFreeMode() {
        #expect(SocketAuthenticationChallenge.isCredentialFreeSuccess("PONG"))
        #expect(SocketAuthenticationChallenge.isCredentialFreeSuccess("OK: Authenticated"))
        #expect(SocketAuthenticationChallenge.isCredentialFreeSuccess(#"{"ok":true,"result":{}}"#))
        #expect(!SocketAuthenticationChallenge.isCredentialFreeSuccess("ERROR: forbidden"))
        #expect(!SocketAuthenticationChallenge.isCredentialFreeSuccess(#"{"ok":false,"error":{"code":"forbidden"}}"#))
        #expect(!SocketAuthenticationChallenge.isCredentialFreeSuccess(#"{"error":{"code":"auth_required"}}"#))
    }
}
