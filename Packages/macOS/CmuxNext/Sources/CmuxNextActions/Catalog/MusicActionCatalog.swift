// cmux's own music player (cx-imt2i, behind labs.previewFeatures): play the person's songs or
// folders (a `url` stream or a `path` skips the picker), and stop. The Now Playing card and the
// media keys run play, pause, next and previous.
// Titles live in MusicActions.xcstrings.

nonisolated enum MusicActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "music.open", title: t("action.music.open", "Play Music…"),
                keywords: ["music", "songs", "audio", "player", "play", "folder", "mp3", "now playing"], category: .window,
                symbol: "music.note", surfaces: [.palette], arguments: [CatalogArgument.optionalPathString, CatalogArgument.urlString]
            ),
            ActionDescriptor(
                id: "music.stop", title: t("action.music.stop", "Stop Music"),
                keywords: ["music", "songs", "audio", "player", "stop", "now playing"], category: .window,
                symbol: "stop.fill", surfaces: [.palette]
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "MusicActions", bundle: .module)
    }
}
