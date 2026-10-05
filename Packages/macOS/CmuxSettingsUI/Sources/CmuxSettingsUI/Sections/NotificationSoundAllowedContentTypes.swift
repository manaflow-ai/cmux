import UniformTypeIdentifiers

/// Audio file types accepted by the global and per-agent sound pickers.
struct NotificationSoundAllowedContentTypes {
    let all: [UTType]

    init() {
        all = [
            UTType(filenameExtension: "aiff"),
            UTType(filenameExtension: "wav"),
            UTType(filenameExtension: "caf"),
            UTType(filenameExtension: "m4a"),
            UTType(filenameExtension: "m4r"),
            UTType.mpeg4Audio,
            UTType(filenameExtension: "mp3"),
        ].compactMap { $0 }
    }
}
