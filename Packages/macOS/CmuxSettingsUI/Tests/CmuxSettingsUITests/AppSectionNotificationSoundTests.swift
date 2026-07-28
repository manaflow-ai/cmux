import Testing
import UniformTypeIdentifiers

@testable import CmuxSettingsUI

@MainActor
@Suite struct AppSectionNotificationSoundTests {
    @Test func customSoundPickerAllowsM4RFiles() throws {
        let ringtoneType = try #require(UTType(filenameExtension: "m4r"))
        let allowedTypes = AppSection.customNotificationSoundAllowedContentTypes

        #expect(allowedTypes.contains { allowedType in
            ringtoneType == allowedType || ringtoneType.conforms(to: allowedType)
        })
    }

    @Test func customSoundPickerAllowsMPEG4AudioFamily() {
        #expect(AppSection.customNotificationSoundAllowedContentTypes.contains(.mpeg4Audio))
    }
}
