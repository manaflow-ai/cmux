import UniformTypeIdentifiers

extension AppSection {
    static let customNotificationSoundAllowedContentTypes: [UTType] = {
        [
            UTType(filenameExtension: "aiff"),
            UTType(filenameExtension: "wav"),
            UTType(filenameExtension: "caf"),
            UTType(filenameExtension: "m4a"),
            UTType(filenameExtension: "m4r"),
            UTType.mpeg4Audio,
            UTType(filenameExtension: "mp3"),
        ].compactMap { $0 }
    }()
}
