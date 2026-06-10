import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

// MARK: - Generic agent hook feed telemetry
extension CMUXCLI {
    func sendAgentFeedTelemetry(workspaceId: String? = nil, ctx: GenericAgentHookContext) {
        ctx.didSendFeedTelemetry = true
        sendFeedTelemetry(
            client: ctx.client,
            source: ctx.def.name,
            subcommand: ctx.subcommand,
            parsedInput: ctx.input,
            workspaceId: workspaceId ?? workspaceArg(ctx: ctx),
            socketPassword: ctx.socketPassword
        )
    }

    func shouldSuppressGenericFeedTelemetry(ctx: GenericAgentHookContext) -> Bool {
        guard ctx.def.name == "hermes-agent",
              let event = ctx.input.object.flatMap({
                  firstString(in: $0, keys: ["hook_event_name", "hookEventName", "event", "event_name"])
              }) ?? ctx.input.rawObject.flatMap({
                  firstString(in: $0, keys: ["hook_event_name", "hookEventName", "event", "event_name"])
              })
        else {
            return false
        }
        return ctx.def.feedHookEvents.contains(event)
    }

    func sendAgentFeedTelemetryUnlessSuppressed(workspaceId: String? = nil, ctx: GenericAgentHookContext) {
        if shouldSuppressGenericFeedTelemetry(ctx: ctx) {
            ctx.didSendFeedTelemetry = true
        } else {
            sendAgentFeedTelemetry(workspaceId: workspaceId, ctx: ctx)
        }
    }
}
