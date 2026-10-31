import AppKit
import CmuxNextDesign
import CmuxNextRemote
import CmuxNextServer
import CmuxNextTestSupport
import Testing

@MainActor @Suite(.serialized, .closesItsWindows) struct SSHConnectRecoveryTests {
    @Test func networkAndDaemonFailuresOfferRecovery() {
        for status: SSHConnectionMachine.Status in [.unreachable("nohost.invalid"), .failed("daemon exited"),
                                                   .authFailed("denied"), .hostKeyUntrusted("changed"), .installFailed("download failed")] {
            #expect(status.needsRecovery)
        }
        for status: SSHConnectionMachine.Status in [.connecting, .connected, .reconnecting, .installing, .offline] {
            #expect(!status.needsRecovery)
        }
    }

    static func spec() -> CmuxDialogSpec {
        SSHConnectRecovery.spec(title: "Cannot Connect to nohost.invalid", detail: "Could not resolve hostname",
                                cancel: "Cancel", copy: "Copy Error", check: "Check Machine", retry: "Retry")
    }

    @Test func copyKeepsRecoveryOpenAndRetryUsesTheSameSessionAction() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var copied: [String] = [], retried = 0, checked = 0, dismissed = 0
        let recovery = SSHConnectRecovery(center: center, retry: { retried += 1 },
            check: { checked += 1 }, copy: { copied.append($0) }, dismissed: { dismissed += 1 })
        recovery.present(Self.spec(), error: "full SSH error", in: window)
        recovery.present(Self.spec(), error: "another failure", in: window)
        #expect(center.records.count == 1)
        center.press(try #require(center.records.first?.id), button: "copy")
        #expect(copied == ["full SSH error"])
        #expect(recovery.isPresented && center.records.count == 1)
        center.press(try #require(center.records.first?.id), button: "retry")
        #expect(retried == 1 && !recovery.isPresented && dismissed == 0)
        recovery.present(Self.spec(), error: "full SSH error", in: window)
        center.press(try #require(center.records.first?.id), button: "check")
        #expect(checked == 1 && dismissed == 1)
        recovery.present(Self.spec(), error: "full SSH error", in: window)
        recovery.stop()
        #expect(center.records.isEmpty && dismissed == 1)
    }

    @Test func retryCanPresentAgainWhenTheFailureIsIdentical() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var retries = 0
        let recovery = SSHConnectRecovery(center: center, retry: { retries += 1 }, check: {}, copy: { _ in }, dismissed: {})
        recovery.present(Self.spec(), error: "same failure", in: window)
        center.press(try #require(center.records.first?.id), button: "retry")
        #expect(retries == 1 && center.records.isEmpty)
        recovery.present(Self.spec(), error: "same failure", in: window)
        #expect(recovery.isPresented && center.records.count == 1)
    }

    @Test func failureOffersRetryDiagnosticsAndFullErrorCopy() {
        let spec = Self.spec()
        #expect(spec.lines == ["Could not resolve hostname"])
        #expect(spec.buttons.map(\.id) == ["cancel", "copy", "check", "retry"])
        #expect(spec.defaultButton?.id == "retry")
        #expect(spec.cancelButton?.id == "cancel")
    }
}
