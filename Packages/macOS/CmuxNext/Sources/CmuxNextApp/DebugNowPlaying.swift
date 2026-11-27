import AppKit
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings
import Foundation
#if DEBUG
import MediaPlayer
#endif

// `debug.now_playing` (DEBUG builds): what this process tells macOS Now Playing
// (Control Center, the media keys): `MPNowPlayingInfoCenter`'s info (`title`,
// `artist`, `album`, `rate`, `media_type`, `artwork`) and `playback_state`, which
// remote commands are enabled, the media hub's sessions (tab, title, playing), and this
// process's visible windows (Chromium's picture-in-picture window is one of them).
// `command` (`play`, `pause`, `toggle`, `next`, `previous`) first runs that media key's
// command as MediaPlayer's handler does (`handled`: a tab was current); `tab` is the
// tab Now Playing shows.
enum DebugNowPlaying {
    static func register(on router: ControlRouter?, services: AppServices) {
        #if DEBUG
        router?.register([
            .mainActor("debug.now_playing") { [weak services] call in
                .value(handle(call.params, services: services))
            },
        ])
        #endif
    }
}

#if DEBUG
extension DebugNowPlaying {
    static func handle(_ params: [String: JSONValue], services: AppServices?) -> JSONValue {
        let nowPlaying = services?.cache.pageRequests.nowPlaying
        let handled = params["command"]?.stringValue.flatMap(BrowserNowPlaying.Command.init(rawValue:)).map { command in
            nowPlaying?.perform(command) ?? false
        }
        guard case .object(var members) = report(services) else { return .null }
        members["tab"] = nowPlaying?.current.map { .string($0.tab.rawValue) } ?? .null
        if let handled { members["handled"] = .bool(handled) }
        return .object(members)
    }

    static func report(_ services: AppServices?) -> JSONValue {
        let center = MPNowPlayingInfoCenter.default()
        var info: [String: JSONValue] = [:]
        if let current = center.nowPlayingInfo {
            info["title"] = (current[MPMediaItemPropertyTitle] as? String).map { .string($0) } ?? .null
            info["artist"] = (current[MPMediaItemPropertyArtist] as? String).map { .string($0) } ?? .null
            info["album"] = (current[MPMediaItemPropertyAlbumTitle] as? String).map { .string($0) } ?? .null
            info["rate"] = (current[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber).map { .number($0.doubleValue) } ?? .null
            let type = (current[MPNowPlayingInfoPropertyMediaType] as? NSNumber)?.uintValue
            info["media_type"] = .string(type == MPNowPlayingInfoMediaType.video.rawValue ? "video"
                : type == MPNowPlayingInfoMediaType.audio.rawValue ? "audio" : "none")
            info["artwork"] = .bool(current[MPMediaItemPropertyArtwork] != nil)
        }
        let state: String = switch center.playbackState {
        case .playing: "playing"
        case .paused: "paused"
        case .stopped: "stopped"
        case .interrupted: "interrupted"
        default: "unknown"
        }
        let remote = MPRemoteCommandCenter.shared()
        let commands: [String: JSONValue] = [
            "play": .bool(remote.playCommand.isEnabled),
            "pause": .bool(remote.pauseCommand.isEnabled),
            "toggle": .bool(remote.togglePlayPauseCommand.isEnabled),
            "next": .bool(remote.nextTrackCommand.isEnabled),
            "previous": .bool(remote.previousTrackCommand.isEnabled),
        ]
        let sessions: [JSONValue] = services.map { services in
            services.cache.pageRequests.media.sessions(in: services.cache).map { session in
                .object([
                    "tab": .string(session.entry.tab.id.rawValue),
                    "title": .string(session.media.title),
                    "playing": .bool(session.media.isPlaying),
                ])
            }
        } ?? []
        let windows: [JSONValue] = NSApp.windows.filter(\.isVisible).map { window in
            .object([
                "class": .string(String(describing: type(of: window))),
                "title": .string(window.title),
                "size": .string("\(Int(window.frame.width))x\(Int(window.frame.height))"),
            ])
        }
        return .object([
            "info": center.nowPlayingInfo == nil ? .null : .object(info),
            "playback_state": .string(state),
            "commands": .object(commands),
            "sessions": .array(sessions),
            "windows": .array(windows),
        ])
    }
}
#endif
