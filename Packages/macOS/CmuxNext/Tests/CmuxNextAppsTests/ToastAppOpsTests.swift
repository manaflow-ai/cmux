import CmuxNextApps
import CmuxNextDesign
import Foundation
import Testing

/// `toast.show` (`cmux.toast`): an app's notice through the app's one toast presenter, one slot per app.
@MainActor
struct ToastAppOpsTests {
    private final class Shown: @unchecked Sendable {
        var toasts: [CmuxToast] = []
    }

    private func request(_ params: AppJSON, app: String = "local/customize") -> AppHostCapabilityRequest {
        AppHostCapabilityRequest(app: app, op: "toast.show", params: params, origin: "script")
    }

    @Test func aToastShowsTheTitleWithTheMessageAsDetailInTheAppsSlot() async throws {
        let shown = Shown()
        let ops = ToastAppOps { toast in shown.toasts.append(toast); return true }
        #expect(ops.families == ["toast"])
        let value = try await ops.handle(request(["title": "Focus started", "message": "25 minutes", "tone": "success"]))
        #expect(value == .null)
        let toast = try #require(shown.toasts.first)
        #expect(toast.id == "app:local/customize", "one slot per app: the next toast replaces it")
        #expect(toast.message == "Focus started")
        #expect(toast.detail == "25 minutes\nFrom local/customize", "the detail names the app that sent it")
        #expect(toast.action == nil)
    }

    @Test func aMissingTitleALongTitleOrAnUnknownToneIsRefused() async {
        let shown = Shown()
        let ops = ToastAppOps { toast in shown.toasts.append(toast); return true }
        for params: AppJSON in [["title": "  "], ["title": .string(String(repeating: "a", count: 201))], ["title": "Hi", "tone": "#ff0000"]] {
            await #expect(throws: AppHostCapabilityError.self) { try await ops.handle(request(params)) }
        }
        #expect(shown.toasts.isEmpty)
    }

    @Test func noWindowIsARetryableFailure() async {
        let ops = ToastAppOps { _ in false }
        do {
            _ = try await ops.handle(request(["title": "Hi"]))
            Issue.record("expected a failure")
        } catch {
            #expect(error.code == "operation.failed")
            #expect(error.retryable)
        }
    }

    @Test func theRouterSendsTheToastFamilyToIt() {
        let router = AppHostCapabilities([ToastAppOps { _ in true }])
        #expect(router.handles("toast.show"))
        #expect(router.families.contains("toast"))
    }
}
