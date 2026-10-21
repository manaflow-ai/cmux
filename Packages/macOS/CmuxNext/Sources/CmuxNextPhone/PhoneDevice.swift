/// One phone a tab can show: a simulator, a real iPhone or a VM.
public struct PhoneDevice: Sendable, Hashable, Codable, Identifiable {
    public let id: PhoneDeviceID
    /// The name the user gave it ("iPhone 18 Pro", "Lawrence's iPhone").
    public var name: String
    /// The marketing model ("iPhone 16 Pro"); used to look up the device frame
    /// in the shared device presets. Equal to `name` when the backend has no model.
    public var model: String
    /// "iOS 27.0".
    public var osVersion: String
    public var state: PhoneDeviceState
    /// For real devices: "usb" or "wifi". Nil for simulators and VMs.
    public var transport: String?

    public init(id: PhoneDeviceID, name: String, model: String, osVersion: String,
                state: PhoneDeviceState, transport: String? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.state = state
        self.transport = transport
    }

    public var mode: PhoneMode { id.mode }
}
