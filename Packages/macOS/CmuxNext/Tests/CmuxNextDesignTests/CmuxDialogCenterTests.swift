import AppKit
@testable import CmuxNextDesign
import Testing

/// R96: one owner for every open dialog, one answer per dialog, the same
/// path for clicks, keys and automation.
@MainActor
struct CmuxDialogCenterTests {
    static let rename = CmuxDialogSpec(title: "Rename Tab", fields: [.text("name", initial: "zsh")],
                                       buttons: [.cancel(), CmuxDialogButton(id: "rename", title: "Rename", role: .default)])
    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aPressAnswersOnceWithTheFieldValues() throws {
        let host = CmuxDialogHeadlessHost()
        let center = CmuxDialogCenter(host: host)
        var answers: [CmuxDialogAnswer] = []
        let id = center.present(Self.rename, in: .window(Self.window())) { answers.append($0) }
        #expect(host.shown.count == 1)
        #expect(center.setValue(.text("build"), for: "name", in: id))
        #expect(center.press(id, button: "rename"))
        #expect(!center.press(id, button: "rename"), "a dialog answers once")
        #expect(answers == [CmuxDialogAnswer(button: "rename", role: .default, values: ["name": .text("build")])])
        #expect(host.shown.isEmpty)
        #expect(center.records.isEmpty)
    }

    @Test func keysTakeTheSamePathAsClicks() {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var answer: CmuxDialogAnswer?
        let id = center.present(Self.rename, in: .window(Self.window())) { answer = $0 }
        #expect(center.key(.escape, in: id))
        #expect(answer?.button == "cancel")
        #expect(answer?.isCancel == true)
        #expect(answer?.isDismissal == false, "Escape is a press")
    }

    @Test func dialogsInOneScopeShowInOrder() {
        let host = CmuxDialogHeadlessHost()
        let center = CmuxDialogCenter(host: host)
        let window = Self.window()
        var order: [String] = []
        let first = center.present(Self.rename, in: .window(window)) { _ in order.append("first") }
        let second = center.present(CmuxDialogSpec(title: "Second", buttons: [.ok()]), in: .window(window)) { _ in order.append("second") }
        #expect(host.shown.map(\.spec.title) == ["Rename Tab"])
        #expect(center.records.map(\.visible) == [true, false])
        center.press(first, button: "rename")
        #expect(host.shown.map(\.spec.title) == ["Second"])
        center.press(second, button: "ok")
        #expect(order == ["first", "second"])
    }

    @Test func aQueuedDialogCanBeAnsweredWithItsInitialValues() {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        let window = Self.window()
        center.present(CmuxDialogSpec(title: "First", buttons: [.ok()]), in: .window(window)) { _ in }
        var answer: CmuxDialogAnswer?
        let queued = center.present(Self.rename, in: .window(window)) { answer = $0 }
        #expect(center.press(queued, button: "rename"))
        #expect(answer?.text("name") == "zsh")
    }

    @Test func aClosedScopeCancelsItsDialog() {
        let host = CmuxDialogHeadlessHost()
        let center = CmuxDialogCenter(host: host)
        var answer: CmuxDialogAnswer?
        center.present(Self.rename, in: .window(Self.window())) { answer = $0 }
        host.closeScope(of: host.shown[0])
        #expect(answer == CmuxDialogAnswer(button: "cancel", role: .cancel, values: ["name": .text("zsh")], isDismissal: true))
    }

    @Test func dismissWithoutACancelButtonReportsCancel() {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var answer: CmuxDialogAnswer?
        let spec = CmuxDialogSpec(title: "Pick", buttons: [CmuxDialogButton(id: "a", title: "A"), CmuxDialogButton(id: "b", title: "B")])
        let id = center.present(spec, in: .app) { answer = $0 }
        #expect(center.dismiss(id))
        #expect(answer?.button == "cancel")
        #expect(answer?.role == .cancel)
        #expect(answer?.isDismissal == true, "nobody pressed a button")
    }

    @Test func observersSeeOpensAndAnswers() {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var events: [CmuxDialogCenter.Event] = []
        let token = center.observe { events.append($0) }
        let id = center.present(Self.rename, in: .app) { _ in }
        center.press(id, button: "cancel")
        center.stopObserving(token)
        center.present(Self.rename, in: .app) { _ in }
        #expect(events.count == 2)
        if case .opened(let record) = events.first {
            #expect(record.id == id && record.scope == "app" && record.visible)
        } else {
            Issue.record("first event is not an open")
        }
        #expect(events.last == .answered(id: id, answer: CmuxDialogAnswer(button: "cancel", role: .cancel, values: ["name": .text("zsh")])))
    }

    @Test func unknownDialogsAndButtonsAreRefused() {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        let id = center.present(Self.rename, in: .app) { _ in }
        #expect(!center.press(id, button: "nope"))
        #expect(!center.press(id + 1, button: "rename"))
        #expect(!center.setValue(.bool(true), for: "name", in: id), "a text field takes text only")
        #expect(!center.dismiss(id + 1))
    }
}
