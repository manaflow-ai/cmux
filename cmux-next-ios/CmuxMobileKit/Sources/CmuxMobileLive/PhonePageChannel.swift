import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "phone-page")

/// The `phone-page` service of the Mac's host (RFD 0089): an agent on the Mac
/// drives a browser tab this iPhone shows in its own web view. The phone holds
/// the channel open for as long as the link lives; the host writes one request
/// line per call (`{"id","method","params"}`) and reads one answer line back
/// (`{"id","ok":true,"value"}` or `{"id","error":{"code","message"}}`). The
/// routing, the verbs and the refusals are the host's (`cmux_phone_page`);
/// this only carries lines to `answer` and back. A Mac without the service
/// refuses the channel, and nothing more is asked on that link.
@MainActor
public enum PhonePageChannel {
    /// The service name (cmux-mobile-host `phone_page.rs`).
    public static let service = "phone-page"
    /// The longest line the host sends or reads.
    static let maxLine = 48 << 20

    /// Answers one verb: its value, or a refusal's code and message. Set by the
    /// shell to the in-app browser tabs (`NativeBrowserTabs.answerPageVerb`).
    public static var answer: (@MainActor (_ method: String, _ params: [String: Any], _ macID: String) async
        -> Result<[String: Any], PageError>)?

    public struct PageError: Error, Sendable {
        public var code: String
        public var message: String
        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    /// Serves `phone-page` on `link` until the channel or the link closes.
    public static func serve(on link: any MacLink, macID: String, deviceName: String) async {
        do {
            let channel = try await link.openChannel(service: service, args: ["name": deviceName])
            var buffer = Data()
            while let bytes = try await channel.receive() {
                buffer.append(bytes)
                while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    guard buffer.distance(from: buffer.startIndex, to: end) <= maxLine else {
                        await channel.close(code: "too_large", reason: "a phone-page line is too long")
                        return
                    }
                    let line = buffer[buffer.startIndex..<end]
                    buffer = Data(buffer[buffer.index(after: end)...])
                    guard !line.isEmpty else { continue }
                    let reply = await answerLine(Data(line), macID: macID)
                    try await channel.send(reply)
                }
                if buffer.count > maxLine {
                    await channel.close(code: "too_large", reason: "a phone-page line is too long")
                    return
                }
            }
            if let closed = channel.closedBy, closed.code != "eof" {
                log.info("phone-page closed: \(closed.code, privacy: .public)")
            }
        } catch {
            log.info("phone-page channel: \(String(describing: error), privacy: .public)")
        }
    }

    /// The answer line to one request line.
    static func answerLine(_ line: Data, macID: String) async -> Data {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = request["id"] as? Int else {
            log.info("phone-page: unreadable request line")
            return encode(["id": 0, "error": ["code": "bad_request", "message": "unreadable request"]])
        }
        guard let method = request["method"] as? String, let params = request["params"] as? [String: Any] else {
            return encode(["id": id, "error": ["code": "bad_request", "message": "a request needs a method and params"]])
        }
        guard let answer else {
            return encode(["id": id, "error": ["code": "tab_not_on_phone", "message": "the iPhone shows no browser tabs"]])
        }
        switch await answer(method, params, macID) {
        case .success(let value):
            return encode(["id": id, "ok": true, "value": value])
        case .failure(let error):
            return encode(["id": id, "error": ["code": error.code, "message": error.message]])
        }
    }

    private static func encode(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
