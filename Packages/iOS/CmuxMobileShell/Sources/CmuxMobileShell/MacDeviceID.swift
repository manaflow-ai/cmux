struct MacDeviceID: Equatable {
    var rawValue: String?

    init(_ rawValue: String?) {
        self.rawValue = rawValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    func matchesPrevious(_ previous: String?, foreground: String?) -> Bool {
        let previous = MacDeviceID(previous)
        return self == previous || (previous.rawValue == nil && self == MacDeviceID(foreground))
    }
}
