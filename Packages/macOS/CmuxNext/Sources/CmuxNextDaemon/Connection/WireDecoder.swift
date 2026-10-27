import Foundation

/// The decoder of daemon wire lines: a `JSONDecoder` that counts each decode into the recorder of the
/// connection the line came from (``DaemonWireStats/Snapshot/jsonDecodes``), so the count is taken
/// where the parse happens. With no recorder (a release build, a test) it only decodes.
struct WireDecoder: Sendable {
    let recorder: DaemonWireStats.Recorder?
    private let decoder = JSONDecoder()

    init(recorder: DaemonWireStats.Recorder?) {
        self.recorder = recorder
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        recorder?.decoded()
        return try decoder.decode(type, from: data)
    }
}
