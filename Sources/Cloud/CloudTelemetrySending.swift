import CmuxAuthRuntime
import Foundation

protocol CloudTelemetrySending: Sendable {
    nonisolated func enqueue(_ span: CloudTelemetrySpan, identity: AuthenticatedSessionIdentity) async
    nonisolated func clearForSignOut() async
}
