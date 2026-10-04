import Foundation

/// The DevTools message id rule of the shim (`cmux_cef_shim.h`): raw sends
/// (`cmux_shim_devtools_send`) and shim-internal calls share one id space
/// per browser. Raw sends use ids from 2^30 up to `Int32.max`; the shim
/// assigns its own calls ids below 2^30. A reply with a raw id arrives as
/// `CEFShimEvent.devToolsMessage`, never as `devToolsResult`.
nonisolated enum CEFDevToolsRawMessage {
    static let firstRawID = 1 << 30

    static func isRawID(_ id: Int) -> Bool {
        id >= firstRawID && id <= Int(Int32.max)
    }

    /// The raw-send id a `devToolsMessage` answers, or nil for an event
    /// (no "id") or any other message.
    static func replyID(in json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["id"] as? NSNumber,
              CFNumberIsFloatType(number) == false,
              isRawID(number.intValue)
        else { return nil }
        return number.intValue
    }
}
