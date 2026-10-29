import CmuxNextActions
import CmuxNextDictation
import Foundation

/// Open Voice Room and Stop Voice Room (`voiceRoom.*`, Labs, plans/cmux-next/voice-room-DESIGN.md),
/// unavailable everywhere while `labs.voiceRoom` is off. Open starts the room's on-device capture
/// (``VoiceRoomHost``) and opens the room page in a browser tab of the front pane.
enum VoiceRoomHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        // Keyframes stay on this Mac: ~/Library/Application Support/cmux/voice-room/frames.
        let host = VoiceRoomHost(frames: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "cmux/voice-room/frames", directoryHint: .isDirectory))
        let off: @MainActor () -> String? = { [weak services] in
            services?.settings?.snapshot.voiceRoom == true ? nil : VoiceRoomStrings.off
        }
        registry.bindEffect("voiceRoom.open", unavailable: off) { [weak services] _ in
            guard let services else { return .done }
            guard let address = VoiceRoomAddress(setting: services.settings?.snapshot.voiceRoomURL ?? "") else {
                return .refused(VoiceRoomStrings.badAddress)
            }
            host.open(address) { [weak services] in services?.settings?.snapshot.voiceRoom == true }
            _ = services.inFrontPane { $0.newBrowserTab(url: address.base) }
            return .done
        }
        registry.bindEffect("voiceRoom.stop", unavailable: off) { _ in
            guard host.isOpen else { return .refused(VoiceRoomStrings.notOpen) }
            host.stop()
            return .done
        }
    }
}

enum VoiceRoomStrings {
    static var off: String {
        String(localized: "voiceRoom.refusal.off", defaultValue: "Voice Room is a Labs feature: turn it on in Settings > Advanced > Labs.",
               table: "VoiceRoom", bundle: .module)
    }

    static var badAddress: String {
        String(localized: "voiceRoom.refusal.address", defaultValue: "The Voice Room address in Settings is not a web address.",
               table: "VoiceRoom", bundle: .module)
    }

    static var notOpen: String {
        String(localized: "voiceRoom.refusal.notOpen", defaultValue: "No Voice Room is open.", table: "VoiceRoom", bundle: .module)
    }
}
