import Testing
import UniformTypeIdentifiers

@testable import CmuxSettingsUI

@MainActor
@Suite struct AppSectionNotificationSoundTests {
    @Test func customSoundPickerAllowsM4RFiles() throws {
        let ringtoneType = try #require(UTType(filenameExtension: "m4r"))
        let allowedTypes = NotificationSoundAllowedContentTypes().all

        #expect(allowedTypes.contains { allowedType in
            ringtoneType == allowedType || ringtoneType.conforms(to: allowedType)
        })
    }

    @Test func customSoundPickerAllowsMPEG4AudioFamily() {
        #expect(NotificationSoundAllowedContentTypes().all.contains(.mpeg4Audio))
    }
}
