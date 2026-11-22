import AppKit
import CmuxNextDesign
@testable import CmuxNextRemoteBrowser
import CmuxNextTestSupport
import Testing

#if DEBUG
/// Theme sweep 3, batch B: a remote tab's JavaScript dialogs (alert, confirm, prompt,
/// beforeunload) were an `NSAlert` sheet, whose chrome can't take the room's theme. They are the
/// cmux dialog, the themed overlay every other page question uses, with the same keys: Return
/// accepts (a prompt answers its text), Escape declines, and the reducer's `close_dialog` withdraws it.
@MainActor @Suite(.serialized, .closesItsWindows) struct RemoteBrowserDialogTests {
    private final class Answers {
        var all: [(token: UInt64, accept: Bool, text: String?)] = []
    }

    private static func tab() throws -> (NSWindow, RemoteBrowserContentView, RemoteBrowserNativeUI, Answers) {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scope.adopt(window)
        let content = RemoteBrowserContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView?.addSubview(content)
        let ui = RemoteBrowserNativeUI(view: content)
        let answers = Answers()
        ui.onDialogAnswer = { token, accept, text in answers.all.append((token, accept, text)) }
        return (window, content, ui, answers)
    }

    private static func openRecord(titled title: String) -> CmuxDialogCenter.Record? {
        CmuxDialogCenter.shared.records.last { $0.spec.title == title }
    }

    @Test func aPromptIsTheThemedCmuxDialogAndReturnAnswersItsText() throws {
        let (window, _, ui, answers) = try Self.tab()
        defer { CmuxDialogCenter.shared.dismissAll(); window.close() }

        ui.showDialog(token: 7, dialog: RbDialog(kind: "prompt", origin: "example.com", message: "Your name?",
                                                 defaultText: "Ada", isReload: false))
        let record = try #require(Self.openRecord(titled: "example.com"), "the prompt is a cmux dialog, not an NSAlert sheet")
        #expect(window.attachedSheet == nil)
        #expect(record.spec.lines == ["Your name?"])
        #expect(record.values.values.contains(.text("Ada")), "the prompt's field starts at the page's default text")
        #expect(ui.openDialogToken == 7)

        #expect(CmuxDialogCenter.shared.key(.return, in: record.id))
        #expect(answers.all.count == 1)
        #expect(answers.all.first?.token == 7)
        #expect(answers.all.first?.accept == true)
        #expect(answers.all.first?.text == "Ada")
        #expect(ui.openDialogToken == nil)
    }

    @Test func escapeDeclinesAConfirm() throws {
        let (window, _, ui, answers) = try Self.tab()
        defer { CmuxDialogCenter.shared.dismissAll(); window.close() }

        ui.showDialog(token: 8, dialog: RbDialog(kind: "confirm", origin: "example.org", message: "Leave?",
                                                 defaultText: nil, isReload: false))
        let record = try #require(Self.openRecord(titled: "example.org"))
        #expect(record.spec.defaultButton != nil && record.spec.cancelButton != nil)
        #expect(CmuxDialogCenter.shared.key(.escape, in: record.id))
        #expect(answers.all.count == 1)
        #expect(answers.all.first?.accept == false)
        #expect(answers.all.first?.text == nil)
    }

    @Test func closeDialogWithdrawsItWithoutAnAnswer() throws {
        let (window, _, ui, answers) = try Self.tab()
        defer { CmuxDialogCenter.shared.dismissAll(); window.close() }

        ui.showDialog(token: 9, dialog: RbDialog(kind: "alert", origin: "example.net", message: "Hi",
                                                 defaultText: nil, isReload: false))
        #expect(Self.openRecord(titled: "example.net") != nil)
        ui.closeDialog(token: 9)
        #expect(Self.openRecord(titled: "example.net") == nil)
        #expect(ui.openDialogToken == nil)
        #expect(answers.all.isEmpty, "the reducer closed it: no answer goes back")
    }
}
#endif
