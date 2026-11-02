import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

@Suite struct ChiefRetryMessageTests {
    private func message(text: String = "", attachments: [ConversationAttachment] = []) -> ConversationMessage {
        ConversationMessage(id: "input", seq: 1, clientMessageID: nil, senderID: "me", sentAt: Date(),
                            text: text, attachments: attachments)
    }

    @Test func anEmptyInputNeverBecomesAnInventedPrompt() {
        #expect(ChiefRetryMessage(message(text: " \n")) == nil)
    }

    @Test func missingAttachmentBytesNeverSendAPartialPrompt() {
        let attachment = ConversationAttachment(id: "file", kind: .file, width: 0, height: 0,
                                                url: nil, localData: nil,
                                                file: ConversationFileInfo(name: "notes.txt", mimeType: "text/plain", byteCount: 5))
        #expect(ChiefRetryMessage(message(text: "Read this", attachments: [attachment])) == nil)
    }

    @Test func anAudioOnlyInputKeepsTheRecordingAndTranscript() throws {
        let bytes = Data("recording".utf8)
        let info = ConversationAudioInfo(duration: 2, waveform: [0.1, 0.8], transcript: "Check the build")
        let attachment = ConversationAttachment(id: "audio", kind: .audio, width: 0, height: 0,
                                                url: nil, localData: bytes, audio: info)
        let retry = try #require(ChiefRetryMessage(message(attachments: [attachment])))
        #expect(retry.message.text.isEmpty)
        #expect(retry.audio?.data == bytes)
        #expect(retry.audio?.info == info)
    }
}
