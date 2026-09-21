import CmuxControlSocket
import CmuxFoundation
import Foundation

extension ComputerUseRuntimeService {
    /// Verifies the helper can perform direct ScreenCaptureKit capture now.
    ///
    /// On macOS 26 this is the prompt-capable check for the separate private
    /// window picker bypass consent. It is called only from the Screenshots
    /// onboarding step after the ordinary Screen Recording grant is present.
    func verifyDirectScreenCapture() async -> Bool {
        await verifyDirectScreenCaptureOutcome() == .ready
    }

    /// The verify direct screen capture outcome exposed to the host application.
    public func verifyDirectScreenCaptureOutcome()
        async -> ComputerUseDirectScreenCaptureVerification
    {
        await serializeHelperLifecycle(cancelledResult: .unavailable) { [weak self] in
            guard
                let self,
                self.desiredEnabled,
                self.acceptsNewLaunches,
                !Task.isCancelled
            else {
                return .unavailable
            }
            await self.startIfNeededWithinLifecycle()
            guard !Task.isCancelled else {
                return .unavailable
            }
            guard let helperURL = self.helperAppURL,
                  let helperIdentity = ComputerUseHelperIdentity(bundleURL: helperURL).read()
            else {
                return .unavailable
            }
            self.onboarding.restore(for: helperIdentity)
            guard let attempt = self.onboarding.beginVerification() else {
                return .unavailable
            }
            let expectedPeerIdentities = Dictionary(
                uniqueKeysWithValues: ComputerUseDaemonProfile.allCases
                    .compactMap { profile in
                        self.processIdentity(for: profile).map {
                            (profile, $0)
                        }
                    }
            )
            let result = await Self.verifyDirectScreenCaptureOutcomes(
                paths: self.paths,
                transport: self.transport,
                expectedPeerIdentities: expectedPeerIdentities
            )
            guard !Task.isCancelled,
                  self.acceptsNewLaunches,
                  expectedPeerIdentities.allSatisfy({ profile, identity in
                      self.processIdentity(for: profile) == identity
                          && AgentPIDProcessIdentity(pid: identity.pid) == identity
                  }) else {
                return .unavailable
            }
            if result == .ready {
                for profile in ComputerUseDaemonProfile.allCases {
                    guard let identity = expectedPeerIdentities[profile],
                          let status = await self.daemonAdmission.permissionStatus(
                              at: self.socketURL(for: profile), peer: identity
                          ), status.helperOwnsPermissions,
                          status.accessibility,
                          status.screenRecording else {
                        await self.onboardingAdmission.withdraw()
                        return .notCapturable
                    }
                }
            }
            return await self.onboardingAdmission.finish(result, attempt: attempt)
        }
    }

    /// Verifies every helper profile that can perform a real capture. Tahoe's
    /// direct-capture consent can be process-generation scoped, so validating
    /// only the native daemon lets the Codex compatibility daemon prompt later
    /// during the first actual Computer Use call.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated static func verifyDirectScreenCaptureOutcomes(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport = SocketTransport(),
        expectedPeerIdentities:
            [ComputerUseDaemonProfile: AgentPIDProcessIdentity]
    ) async -> ComputerUseDirectScreenCaptureVerification {
        for profile in ComputerUseDaemonProfile.allCases {
            guard
                let expectedPeerIdentity = expectedPeerIdentities[profile],
                AgentPIDProcessIdentity(pid: expectedPeerIdentity.pid)
                    == expectedPeerIdentity
            else {
                return .unavailable
            }
            let result = await verifyDirectScreenCaptureOutcome(
                paths: paths,
                transport: transport,
                expectedPeerIdentity: expectedPeerIdentity,
                socketURL: Self.socketURL(for: profile, paths: paths)
            )
            guard result == .ready else { return result }
        }
        return .ready
    }

    /// Socket-level host request kept internal for peer/capability regression
    /// coverage. A normal bearer token cannot invoke this daemon method.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated static func verifyDirectScreenCapture(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport = SocketTransport(),
        expectedPeerIdentity: AgentPIDProcessIdentity
    ) async -> Bool {
        await verifyDirectScreenCaptureOutcome(
            paths: paths,
            transport: transport,
            expectedPeerIdentity: expectedPeerIdentity
        ) == .ready
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated static func verifyDirectScreenCaptureOutcome(
        paths: ComputerUseRuntimePaths,
        transport: SocketTransport = SocketTransport(),
        expectedPeerIdentity: AgentPIDProcessIdentity,
        socketURL: URL? = nil
    ) async -> ComputerUseDirectScreenCaptureVerification {
        guard
            let response = await sendDaemonRequest(
                ["method": "verify_screen_capture"],
                paths: paths,
                transport: transport,
                timeout: 60,
                expectedPeerIdentity: expectedPeerIdentity,
                socketURL: socketURL ?? paths.daemonSocketURL
            )
        else {
            return .unavailable
        }
        guard
            response["ok"] as? Bool == true,
            let result = response["result"] as? [String: Any],
            let capturable = result["capturable"] as? Bool
        else {
            return .unavailable
        }
        return capturable ? .ready : .notCapturable
    }

}
