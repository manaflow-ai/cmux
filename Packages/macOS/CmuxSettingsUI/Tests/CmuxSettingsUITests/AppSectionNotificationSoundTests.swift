import Testing
import UniformTypeIdentifiers

@testable import CmuxSettingsUI

@MainActor
@Suite struct AppSectionNotificationSoundTests {
    @Test func customSoundPickerAllowsM4RFilesWhenSystemTypeIsAvailable() {
        guard let ringtoneType = UTType(filenameExtension: "m4r") else {
            return
        }
        let allowedTypes = AppSection.customNotificationSoundAllowedContentTypes

        #expect(allowedTypes.contains { allowedType in
            ringtoneType == allowedType || ringtoneType.conforms(to: allowedType)
        })
    }

    @Test func customSoundPickerAllowsMPEG4AudioFamily() {
        #expect(AppSection.customNotificationSoundAllowedContentTypes.contains(.mpeg4Audio))
    }
}
