import CmuxSettings

actor UserDefaultsSettingsEventRecorder<Value: SettingCodable> {
    private var events: [UserDefaultsSettingsValueEvent<Value>] = []

    func append(_ event: UserDefaultsSettingsValueEvent<Value>) {
        events.append(event)
    }

    func count() -> Int {
        events.count
    }

    func snapshot() -> [UserDefaultsSettingsValueEvent<Value>] {
        events
    }
}
