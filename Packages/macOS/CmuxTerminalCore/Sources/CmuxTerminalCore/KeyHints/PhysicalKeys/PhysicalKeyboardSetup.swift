/// Everything that decides which physical keys produce a chord: the
/// connected keyboards, Karabiner-Elements' selected profile, `hidutil`'s
/// `UserKeyMapping`, and System Settings' modifier keys.
///
/// Build one from what the app read, then ask it for advice on a hint's keys:
///
/// ```swift
/// let setup = PhysicalKeyboardSetup(
///     connectedKeyboards: keyboards,
///     karabiner: KarabinerProfile(configurationData: data),
///     userKeyMapping: HIDKeyMapping(hidutilOutput: output),
///     modifierKeys: SystemModifierKeyMappings(globalDomains: [anyHost, currentHost]),
///     application: KarabinerFrontmostApplication(bundleIdentifier: "com.cmuxterm.app", executablePath: nil)
/// )
/// setup.advice(forAgentKeys: ["ctrl+o"])
/// ```
public struct PhysicalKeyboardSetup: Sendable {
    /// Connected keyboards, without Karabiner's virtual keyboard, one per
    /// vendor, product, and name.
    public private(set) var keyboards: [KeyboardDevice]
    var karabiner: KarabinerProfile?
    /// Karabiner's virtual keyboard, present while Karabiner runs.
    var karabinerVirtualKeyboard: KeyboardDevice?
    var userKeyMapping: HIDKeyMapping
    var modifierKeys: SystemModifierKeyMappings
    var application: KarabinerFrontmostApplication

    /// - Parameters:
    ///   - connectedKeyboards: Keyboards from the HID registry, including
    ///     Karabiner's virtual keyboard when it runs. Karabiner's profile
    ///     only applies while that virtual keyboard is present.
    ///   - karabiner: The selected Karabiner-Elements profile, if any.
    ///   - userKeyMapping: `hidutil`'s `UserKeyMapping`.
    ///   - modifierKeys: System Settings' modifier keys per keyboard.
    ///   - application: cmux, for Karabiner's frontmost-application conditions.
    public init(
        connectedKeyboards: [KeyboardDevice],
        karabiner: KarabinerProfile?,
        userKeyMapping: HIDKeyMapping,
        modifierKeys: SystemModifierKeyMappings,
        application: KarabinerFrontmostApplication
    ) {
        var keyboards: [KeyboardDevice] = []
        for keyboard in connectedKeyboards where !keyboard.isKarabinerVirtualKeyboard && !keyboards.contains(keyboard) {
            keyboards.append(keyboard)
        }
        self.keyboards = keyboards
        self.karabinerVirtualKeyboard = connectedKeyboards.first(where: \.isKarabinerVirtualKeyboard)
        self.karabiner = karabiner
        self.userKeyMapping = userKeyMapping
        self.modifierKeys = modifierKeys
        self.application = application
    }

    /// How `keyboard`'s keys reach the app.
    ///
    /// - Parameter keyboard: The keyboard, or `nil` when the connected
    ///   keyboards are unknown; then per-keyboard settings don't apply and
    ///   Karabiner rules that check the keyboard count as unreadable.
    public func remap(for keyboard: KeyboardDevice?) -> PhysicalKeyRemap {
        var stage: PhysicalKeyRemap.KarabinerStage?
        var reachesMacOSAs = keyboard
        if let karabiner, let virtual = karabinerVirtualKeyboard {
            let settings = keyboard.flatMap(karabiner.deviceSettings(for:))
            if settings?.ignore != true {
                reachesMacOSAs = virtual
                stage = PhysicalKeyRemap.KarabinerStage(
                    simpleModifications: karabiner.simpleModifications.merging(
                        settings?.simpleModifications ?? [:],
                        uniquingKeysWith: { _, device in device }
                    ),
                    manipulators: karabiner.manipulators.compactMap { manipulator in
                        var certain = true
                        for condition in manipulator.conditions {
                            switch condition.holds(device: keyboard, application: application) {
                            case false?: return nil
                            case nil: certain = false
                            case true?: break
                            }
                        }
                        return (manipulator, certain)
                    }
                )
            }
        }
        let modifierKeys = reachesMacOSAs.map(modifierKeys.mapping(for:)) ?? .identity
        return PhysicalKeyRemap(karabiner: stage, system: userKeyMapping.followed(by: modifierKeys))
    }

    /// Physical keys to press for `keys` on each keyboard where they differ
    /// from the printed keys, grouped by keyboards that agree.
    ///
    /// Empty when every keyboard presses the keys as printed, or cmux can't
    /// tell.
    ///
    /// - Parameter keys: A hint's keys in `TerminalSurface.sendNamedKey`
    ///   form, pressed in order.
    public func advice(forAgentKeys keys: [String]) -> [PhysicalKeyAdvice] {
        let printed = keys.map { LogicalKeyChord(agentKey: $0)?.asPrinted }
        guard !keys.isEmpty, !printed.contains(nil) else { return [] }
        let targets: [KeyboardDevice?] = keyboards.isEmpty ? [nil] : keyboards
        var advice: [PhysicalKeyAdvice] = []
        for keyboard in targets {
            let remap = remap(for: keyboard)
            let resolutions = keys.map(remap.resolve(agentKey:))
            var chords: [PhysicalKeyChord] = []
            var notes: [PhysicalKeyNote] = []
            var viaRule = false
            var differs = false
            for (resolution, printedChord) in zip(resolutions, printed) {
                switch resolution {
                case .asPrinted:
                    if let printedChord { chords.append(printedChord) }
                case let .press(press):
                    differs = true
                    chords.append(press.chord)
                    notes += press.notes.filter { !notes.contains($0) }
                    viaRule = viaRule || press.viaKarabinerRule
                }
            }
            guard differs else { continue }
            let name = keyboard?.name ?? ""
            if let index = advice.firstIndex(where: { $0.chords == chords && $0.notes == notes && $0.viaKarabinerRule == viaRule }) {
                if !advice[index].keyboardNames.contains(name) { advice[index].keyboardNames.append(name) }
            } else {
                advice.append(PhysicalKeyAdvice(
                    keyboardNames: [name],
                    appliesToEveryKeyboard: false,
                    chords: chords,
                    notes: notes,
                    viaKarabinerRule: viaRule
                ))
            }
        }
        let allNames = Set(targets.map { $0?.name ?? "" })
        for index in advice.indices where Set(advice[index].keyboardNames) == allNames {
            advice[index].appliesToEveryKeyboard = true
        }
        return advice
    }
}
