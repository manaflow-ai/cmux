// DEBUG builds only: no demo plumbing ships in Release or Production.
#if DEBUG && os(iOS)
import CmuxScreenKit
import CoreText
import Foundation

/// `-CmuxMobileScreenSharingFollowDemo` (with `-CmuxMobileScreenSharingDemo`):
/// Follow mode on the built-in demo desktop, without a Mac. It types a long
/// command line into the desktop's terminal-like window and sends the focus
/// events a Mac would (its display, the focused window, the caret after
/// each character), so the crop can be seen following the typing. The
/// first two seconds show the fitted view with Follow off.
@MainActor
final class ScreenSharingFollowDemo {
    static var isRequested: Bool { CommandLine.arguments.contains("-CmuxMobileScreenSharingFollowDemo") }

    /// What it types: one line longer than a narrow portrait crop is wide.
    static let line = "git log --oneline --decorate --graph -- cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileScreenSharing | grep -i follow"

    let camera = ScreenSharingFollowCamera()
    private var script: Task<Void, Never>?

    func start(_ session: ScreenSession) {
        camera.attach(to: session)
        script?.cancel()
        // task-owner: the demo's typing script; cancelled with the demo (stop) or when the session closes
        script = Task { [weak self, weak session] in
            while let session, !Self.isConnected(session) {
                guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return }
            }
            guard let self, let session else { return }
            await run(session)
        }
    }

    func stop() {
        script?.cancel()
        script = nil
    }

    private static func isConnected(_ session: ScreenSession) -> Bool {
        if case .connected = session.phase { return true }
        return false
    }

    private func run(_ session: ScreenSession) async {
        // The demo desktop (ScreenSession's demo server) and its status window, the "terminal".
        send(#"{"t_us":0,"kind":"source","w":1440,"h":900}"#)
        send(#"{"t_us":0,"kind":"window","id":1,"x":40,"y":40,"w":1360,"h":220}"#)
        guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
        camera.toggle()
        guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
        var typed = ""
        for character in Self.line {
            session.type(String(character))
            typed.append(character)
            let caret = Self.caret(after: typed)
            send(#"{"t_us":0,"kind":"caret","x":\#(caret.minX),"y":\#(caret.minY),"w":2,"h":\#(caret.height)}"#)
            guard (try? await Task.sleep(for: .milliseconds(70))) != nil else { return }
        }
    }

    private func send(_ json: String) {
        camera.receive(Data(json.utf8))
    }

    /// Where the demo desktop draws the caret after `typed`: its status
    /// window's prompt line (`DemoScene.drawStatus`: Menlo 15 at x 58, y 131).
    static func caret(after typed: String) -> CGRect {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 15, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "> " + typed, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return CGRect(x: 58 + width, y: 131, width: 2, height: 18)
    }
}
#endif
