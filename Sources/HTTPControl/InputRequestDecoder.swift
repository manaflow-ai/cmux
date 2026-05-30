import CmuxTerminalAccess
import Foundation

/// JSON decoder for `POST /v1/surfaces/{id}/input` bodies.
///
/// Maps the v1 wire shape `{"type":"text"|"keys"|"raw"|"paste"|
/// "mouse"|"focus", ...}` onto ``CmuxTerminalAccess/InputRequest``.
/// Decode failures throw ``CmuxTerminalAccess/TerminalAccessError`` so
/// the route layer can map directly to the JSON HTTP envelope.
///
/// `allowRaw` gates the `type=raw` decode path per D9 / Errata E3;
/// when `false` the decoder throws ``TerminalAccessError/forbidden``
/// before the body is even parsed for raw bytes.
enum InputRequestDecoder {
    /// Decodes `body` into an ``CmuxTerminalAccess/InputRequest``.
    ///
    /// - Parameters:
    ///   - handle: The surface handle extracted from the request path
    ///     by the route registrar; the decoder does **not** re-parse
    ///     the URL.
    ///   - body: The raw request body bytes.
    ///   - allowRaw: Closure-resolved gate from
    ///     ``HTTPControlSettings/allowRawInput``. Closed by default;
    ///     opened opt-in by the embedder.
    static func decode(
        handle: SurfaceHandle,
        body: Data,
        allowRaw: Bool
    ) throws -> InputRequest {
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw TerminalAccessError.badRequest(reason: "body must be JSON object")
        }
        let focus = (obj["focus"] as? Bool) ?? false
        switch obj["type"] as? String {
        case "text":
            let t = (obj["text"] as? String) ?? ""
            let submit = (obj["submit"] as? Bool) ?? false
            return InputRequest(
                handle: handle,
                payload: .text(t, submit: submit),
                focusSurface: focus
            )
        case "paste":
            let t = (obj["text"] as? String) ?? ""
            return InputRequest(
                handle: handle,
                payload: .paste(t),
                focusSurface: focus
            )
        case "keys":
            let names = (obj["keys"] as? [String]) ?? []
            do {
                let events = try names.map { try KeyEvent.parse($0) }
                return InputRequest(
                    handle: handle,
                    payload: .keys(events),
                    focusSurface: focus
                )
            } catch {
                throw TerminalAccessError.badRequest(
                    reason: "keys parse failed: \(error)"
                )
            }
        case "raw":
            guard allowRaw else {
                throw TerminalAccessError.forbidden(reason: "type=raw disabled")
            }
            guard let b64 = obj["bytes_base64"] as? String,
                  let data = Data(base64Encoded: b64) else {
                throw TerminalAccessError.badRequest(reason: "bytes_base64 invalid")
            }
            return InputRequest(
                handle: handle,
                payload: .raw(data),
                focusSurface: focus
            )
        case "mouse":
            do {
                let m = try MouseEvent.parse(obj)
                return InputRequest(
                    handle: handle,
                    payload: .mouse(m),
                    focusSurface: focus
                )
            } catch {
                throw TerminalAccessError.badRequest(
                    reason: "mouse parse failed: \(error)"
                )
            }
        case "focus":
            let gained = (obj["gained"] as? Bool) ?? true
            return InputRequest(
                handle: handle,
                payload: .focus(gained: gained),
                focusSurface: focus
            )
        default:
            throw TerminalAccessError.badRequest(reason: "unknown type")
        }
    }
}
