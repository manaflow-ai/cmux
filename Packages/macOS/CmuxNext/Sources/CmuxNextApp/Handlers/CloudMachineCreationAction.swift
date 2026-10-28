import CmuxNextActions
import CmuxNextCloud

/// The shared native action used by the Computer menu, Add Device and palette.
@MainActor
struct CloudMachineCreationAction {
    let context: AppActionContext

    func bind(into registry: ActionRegistry, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud
        let signedOutCreation = cloud.signedOutCreation
        let bound = registry.bindEffect("newCloudMachine", requires: nil, unavailable: reason) { invocation in
            let request = try CloudHandlers.newMachineRequest(invocation)
            let actionOrigin = CloudHandlers.origin(of: invocation)
            let window = invocation.allowsViewChange ? context.services.windows.active?.state : nil
            let start: @MainActor () -> Void = {
                guard cloud.isSignedIn, cloud.unavailableReason == nil else { return }
                if request.isDefault, actionOrigin == .user, window != nil {
                    CloudHandlers.beginWorkspaceSetup(context, window: window, askedBy: invocation.callerAgentSession)
                    return
                }
                let flow = CloudHandlers.creationFlow(context, startedByPerson: actionOrigin == .user,
                                         askedBy: invocation.callerAgentSession)
                guard request.isDefault else { return CloudHandlers.createRequested(request, flow: flow, window: window, context) }
                CloudHandlers.reportCreatedMachine(flow.start(in: window, existing: nil), context)
            }
            guard !cloud.isSignedIn else {
                signedOutCreation.cancel()
                start()
                return .done
            }
            guard actionOrigin == .user else {
                return .refused(CloudStrings.signInFirst)
            }
            let expected = signedOutCreation.reserve()
            return .waiting(.network) {
                let resumed = await withTaskCancellationHandler {
                    await signedOutCreation.perform(expected: expected, signIn: { await cloud.auth.signIn() }) {
                        guard cloud.isSignedIn, cloud.unavailableReason == nil else { return }
                        // Keep the original destination even if another window became
                        // active; closing it cancels the deferred creation.
                        if let window, context.services.windows.controller(for: window.id) == nil { return }
                        start()
                    }
                } onCancel: {
                    Task { @MainActor in signedOutCreation.cancel(expected: expected) }
                }
                // Hosted sign-in cancellation is an expected no-op, like the
                // standalone sign-in action; the coordinator has consumed the
                // pending intent and will not replay it.
                _ = resumed
                return nil
            }
        }
        assert(bound, "newCloudMachine is not in the action catalog")
    }
}
