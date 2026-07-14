actor ReconnectResultProbe {
    private var result: Bool?

    func record(_ result: Bool) {
        self.result = result
    }

    func value() -> Bool? {
        result
    }
}
