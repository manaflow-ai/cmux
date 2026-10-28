// The Voice Room (labs.voiceRoom, plans/cmux-next/voice-room-DESIGN.md): an unofficial Labs room
// where people and Chief talk. Open starts on-device mic and screen-text capture and opens the
// room page in a tab; Stop ends the capture. Both are unavailable while the Labs switch is off, so
// a default app shows neither. Out of the main menu: an unavailable item there shows greyed out.
// Titles live in ActionCatalog.xcstrings.

nonisolated enum VoiceRoomActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "voiceRoom.open", title: t("action.voiceRoom.open", "Open Voice Room"),
                keywords: ["voice", "room", "call", "meeting", "talk", "transcribe", "screen", "chief", "labs"],
                category: .agents, symbol: "person.wave.2", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "voiceRoom.stop", title: t("action.voiceRoom.stop", "Stop Voice Room"),
                keywords: ["voice", "room", "call", "meeting", "stop", "recording", "mic", "labs"],
                category: .agents, symbol: "stop.circle", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "ActionCatalog", bundle: .module)
    }
}
