import CmuxVNCWebRTC
import CoreGraphics
import Foundation

// cmux-screen-sharing-webrtc: one WebRTC viewer's session (the iPhone's Screen Sharing viewer),
// captured with ScreenCaptureKit and controlled with CGEvent. It ships inside the Screen Sharing
// helper ("<app> Screen Sharing.app/Contents/MacOS"), and only the helper's hidden mode
// `cmux-screen-sharing __webrtc-host` starts it, as its child with responsibility kept, so macOS
// checks the helper's Screen Recording and Accessibility grants for it, never the app's. The app
// relays the session's signaling and the windows to leave out on stdin and stdout
// (ScreenHostRelay.swift); diagnostics go to stderr. People and agents never run it.
//
//   cmux-screen-sharing-webrtc        (stdin: the app's lines; stdout: this side's lines)
@main
enum WebRTCHostMain {
    static func main() async {
        guard CommandLine.arguments.count == 1 else {
            FileHandle.standardError.write(Data("usage: cmux-screen-sharing-webrtc (started by the Screen Sharing helper)\n".utf8))
            exit(2)
        }
        let log: @Sendable (String) -> Void = { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
        let runner = ScreenRelayRunner.standardIO(log: log) { setup, exclusions in
            // SECURITY: the capture leaves out the windows the app sent, from its first frame, and
            // follows each new list at once.
            ScreenStreamHost(name: setup.name, viewOnly: setup.viewOnly, backend: {
                let backend = ScreenCaptureBackend(log: log)
                backend.excludedWindowIDs = { Set(exclusions.windowIDs.map { CGWindowID($0) }) }
                exclusions.onChange { [weak backend] in backend?.exclusionsChanged() }
                return backend
            }, log: log)
        }
        exit(await runner.run())
    }
}
