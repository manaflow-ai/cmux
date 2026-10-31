#if DEBUG && os(iOS)
import CmuxMobileTransport
import Foundation
import os

/// Synthetic host messages for the real browser model and its production controls.
/// This transport never opens a network connection or reads account data.
final class BrowserEventsDemoTransport: BrowserStreamOpening, Sendable {
    let scene: String

    init(scene: String) { self.scene = scene }

    func openBrowser(tab: String, url: String?, sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection {
        BrowserEventsDemoConnection(sink: sink, scene: scene)
    }
}

private final class BrowserEventsDemoConnection: BrowserStreamConnection, Sendable {
    private struct State {
        var closed = false
        var task: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let sink: any BrowserStreamSink
    private let scene: String

    init(sink: any BrowserStreamSink, scene: String) {
        self.sink = sink
        self.scene = scene
        // One bounded fixture sequence, cancelled by close. Give the model time to
        // attach the returned connection before the synthetic host welcomes it.
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                self?.emit(#"{"t":"welcome","caps":[]}"#)
                self?.emit(#"{"t":"rb.screen_applied"}"#)
                try await Task.sleep(for: .milliseconds(500))
                self?.showInitialEvent()
            } catch { return }
        }
        state.withLock { $0.task = task }
    }

    private func emit(_ json: String) {
        guard !state.withLock({ $0.closed }) else { return }
        sink.browserMessage(Data(json.utf8))
    }

    private func showInitialEvent() {
        switch scene {
        case "select":
            emit(#"""
            {"t":"rb.menu.show","token":2,"menu":{"kind":"select","selected":2,"multiple":false,"items":[
              {"id":0,"type":"group","label":"Teams & projects"},
              {"id":1,"type":"option","label":"Design"},
              {"id":2,"type":"option","label":"R&D"},
              {"id":3,"type":"option","label":"Engineering"},
              {"id":4,"type":"option","label":"Archived","enabled":false}]}}
            """#)
        case "dialog", "confirm":
            emit(#"{"t":"rb.dialog.show","token":3,"dialog":{"kind":"confirm","origin":"https://events.example.test","message":"Save changes to this project?"}}"#)
        case "prompt":
            emit(#"{"t":"rb.dialog.show","token":3,"dialog":{"kind":"prompt","origin":"https://events.example.test","message":"Name this project","default_text":"Research notes"}}"#)
        default: break
        }
    }

    func send(message: Data) throws {}

    func send(input: Data, mustDeliver: Bool) throws {
        guard scene == "context",
              let event = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              event["e"] as? String == "pointer", event["kind"] as? String == "up",
              (event["button"] as? NSNumber)?.intValue == 2 else { return }
        // Answer the actual StreamView long-press request, so UIKit presents the
        // production menu through the same deferred callback as a linked Mac.
        emit(#"""
        {"t":"rb.menu.show","token":1,"menu":{"kind":"context","items":[
          {"id":33000,"type":"command","label":"&Back","enabled":true},
          {"id":33001,"type":"command","label":"&Forward","enabled":false},
          {"id":33002,"type":"command","label":"&Reload","enabled":true}]}}
        """#)
    }

    func requestKeyframe() {}
    func noteDecode(micros: UInt32) {}
    func stats() -> BrowserStreamStats { BrowserStreamStats() }
    func nowMicros() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000 }
    func setVisible(_ visible: Bool) {}

    func close() {
        let task = state.withLock { value in
            value.closed = true
            let task = value.task
            value.task = nil
            return task
        }
        task?.cancel()
    }
}
#endif
