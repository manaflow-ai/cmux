public import CmuxNextDesign

extension SwitchFrameTimer {
    /// A debug socket method over this timer (`debug.tab_switch`, `debug.new_workspace`): `action`
    /// `start` or `stop` (else a read), then whether it records and its samples under `key`.
    public func handle(_ params: [String: JSONValue], key: String) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start": start()
        case "stop": stop()
        default: break
        }
        return ["recording": .bool(isRecording), key: .array(samples.map { .object($0.mapValues { JSONValue.number($0) }) })]
    }
}
