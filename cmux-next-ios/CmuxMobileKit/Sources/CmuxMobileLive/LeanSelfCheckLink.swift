#if os(iOS)
import CmuxMobileTransport
import Foundation
import OSLog
import UIKit

private let log = Logger(subsystem: "dev.cmux.mobile", category: "self-check")

/// The phone's end of the Mac host's `self-check` service (cmux-mobile-host `self_check.rs`):
/// open for as long as the Mac's link lives, idle until `cmux device self-check` on the Mac
/// asks for a run. Lines of JSON both ways:
///
/// - phone: `{"hello":{"version":1,"device":{...}}}` once;
/// - Mac: `{"run":ID,"rows":[1,...]}`;
/// - phone: `{"run":ID,"case":{...}}` per case (``LeanSelfCheck``), then `{"run":ID,"done":true}`
///   or `{"run":ID,"error":...}`.
///
/// A Mac without the service (an older host) refuses it and nothing more is asked on that link.
@MainActor
final class LeanSelfCheckLink {
    static let service = "self-check"

    private let channel: any LinkChannel

    private init(channel: any LinkChannel) {
        self.channel = channel
    }

    /// Serves `link`'s `self-check` channel until it or the link closes.
    static func serve(on link: any MacLink) async {
        do {
            let channel = try await link.openChannel(service: service, args: [:])
            await LeanSelfCheckLink(channel: channel).serve()
        } catch {
            log.info("self-check channel: \(String(describing: error), privacy: .public)")
        }
    }

    private func serve() async {
        do {
            try await send(["hello": ["version": 1, "device": Self.device()]])
            var buffer = Data()
            while let chunk = try await channel.receive() {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let run = object["run"] as? String else { continue }
                    let asked = (object["rows"] as? [Int] ?? []).filter { (1...9).contains($0) }
                    let rows = asked.isEmpty ? Array(1...9) : Array(Set(asked)).sorted()
                    await LeanSelfCheck().run(rows: rows) { [weak self] message in
                        var message = message
                        message["run"] = run
                        try? await self?.send(message)
                    }
                }
            }
        } catch {
            log.info("self-check channel ended: \(String(describing: error), privacy: .public)")
        }
    }

    private func send(_ object: [String: Any]) async throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try await channel.send(data)
    }

    /// What the Mac's report names: the phone's model, system, this app's version and build kind.
    static func device() -> [String: Any] {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        return [
            "model": model, "system": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "app": "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            "build": build,
        ]
    }
}
#endif
