public import Foundation

// The decode path of daemon events (plans/cmux-next/chrome-parity/p05-ipc.md, task 022). The
// generated `DaemonWireEvent` (CmuxNextWireGen's EventEmitter) conforms to ``WireEventSet``; the
// logic lives here so a test can run it over a fixture set. A JSON line costs one decode: the
// name comes from a byte scan (``WireEventNameScanner``), the id from the method table, and the
// event's own type is the only thing decoded. A TYPED_EVENT frame already carries its id, so it
// skips the scan too. Mojo dispatches a message on its header ordinal and deserializes the payload
// once into the method's params struct (mojo/public/tools/bindings/generators/cpp_templates/
// interface_stub_declaration.tmpl).

/// A set of daemon events: a case per event the schema gives an id, and `unknown` for the rest.
public protocol WireEventSet: Sendable {
    /// The event `id` holds, decoded from `payload` with one call to `decoder`; nil when this set
    /// has no case for `id`.
    static func decodeKnown(id: EventID, payload: Data, using decoder: some WireEventDecoding) throws -> Self?

    /// An event this set has no case for, kept as its name and its undecoded bytes.
    static func unknown(name: String, raw: Data) -> Self
}

extension WireEventSet {
    /// Decodes one event line (`{"event": "<name>", ...}`): the name from a byte scan, falling back
    /// to a parse of the `event` field when the scan cannot read it, then one decode of the line.
    /// An event `table` does not know is `unknown` and is not decoded.
    public static func decode(
        line: Data,
        table: MethodTable,
        using decoder: some WireEventDecoding
    ) throws(WireEventDecodeError) -> Self {
        let name = try eventName(in: line, using: decoder)
        guard let id = table.eventID(named: name) else { return unknown(name: name, raw: line) }
        return try decode(id: id, name: name, payload: line, using: decoder)
    }

    /// Decodes a TYPED_EVENT frame's payload: `eventID` picks the type, so a known id is neither
    /// scanned nor parsed for its name. The payload is the event's JSON object, the same bytes as
    /// its line, `event` included (sdk-schema.json makes that literal a required field of every
    /// event payload). An id `table` does not know (a newer daemon's event) is `unknown` and never
    /// an error: its name is the scanned `event`, or the id (`0xC7FF`) when the scan finds none.
    public static func decode(
        eventID: EventID,
        payload: Data,
        table: MethodTable,
        using decoder: some WireEventDecoding
    ) throws(WireEventDecodeError) -> Self {
        guard let name = table.event(eventID)?.name else {
            return unknown(name: WireEventNameScanner.name(in: payload) ?? eventID.description, raw: payload)
        }
        return try decode(id: eventID, name: name, payload: payload, using: decoder)
    }

    private static func decode(
        id: EventID,
        name: String,
        payload: Data,
        using decoder: some WireEventDecoding
    ) throws(WireEventDecodeError) -> Self {
        let known: Self?
        do {
            known = try decodeKnown(id: id, payload: payload, using: decoder)
        } catch {
            throw WireEventDecodeError.payload(event: name, reason: "\(error)")
        }
        guard let known else { return unknown(name: name, raw: payload) }
        return known
    }

    /// The line's top-level `event`: scanned, or parsed when the scan cannot read it.
    private static func eventName(in line: Data, using decoder: some WireEventDecoding) throws(WireEventDecodeError) -> String {
        if let name = WireEventNameScanner.name(in: line) { return name }
        do {
            return try decoder.decode(EventNameField.self, from: line).event
        } catch {
            throw WireEventDecodeError.noEventName(reason: "\(error)")
        }
    }
}

/// The `event` field alone: the full-parse fallback of the name scan.
private struct EventNameField: Decodable {
    let event: String
}
