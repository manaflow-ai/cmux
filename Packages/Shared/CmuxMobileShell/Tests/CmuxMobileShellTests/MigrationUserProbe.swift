actor MigrationUserProbe {
    private var currentValue: String?

    init(value: String?) {
        currentValue = value
    }

    func value() -> String? { currentValue }

    func setValue(_ value: String?) {
        currentValue = value
    }
}
