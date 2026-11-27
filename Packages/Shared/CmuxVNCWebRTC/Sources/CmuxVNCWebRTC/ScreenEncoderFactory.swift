import Foundation
import WebRTC

/// The default encoders, with H.264 opened at VideoToolbox's AutoLevel.
///
/// libwebrtc's H.264 encoder caps its frame rate at what the negotiated
/// level allows for the frame size: the level's most samples a second over
/// the frame's (16-aligned) pixels. Level 5.2 allows 530,841,600, so 68 fps
/// at 3456×2234 (a 16" MacBook Pro's built-in display) and 89 fps at
/// 3024×1964 (14"), and it sets that as VideoToolbox's expected frame rate.
/// Measured at 3456×2234 with 120 fps input: an M1 Max's hardware encoder
/// put out 44 fps with that hint and 55 without; a stream end to end on an
/// M4 Pro decoded 39 fps with it and 67 without. libwebrtc knows no level
/// above 5.2, so declaring a higher one is not possible.
///
/// Given a level below 3, the same encoder opens VideoToolbox at AutoLevel
/// (VideoToolbox writes the level the size and rate need) and sets no rate
/// cap. Only the encoder's own setup changes: the SDP still offers and
/// answers level 5.2 (``ScreenDecoderFactory``), and the receiving hardware
/// decoder reads the stream's real level from its sequence header.
final class ScreenEncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let base = RTCDefaultVideoEncoderFactory()

    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        base.createEncoder(Self.encoderInfo(info))
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        base.supportedCodecs()
    }

    /// The `level_idc` byte libwebrtc maps to AutoLevel and no rate cap (level 1).
    static let autoLevel = "0a"

    /// The codec info the encoder is created with: an H.264 format's
    /// profile kept and its level replaced by ``autoLevel``; anything else as negotiated.
    static func encoderInfo(_ info: RTCVideoCodecInfo) -> RTCVideoCodecInfo {
        #if DEBUG
        if usesNegotiatedLevel { return info }
        #endif
        guard info.name == kRTCVideoCodecH264Name, let level = info.parameters["profile-level-id"], level.count == 6 else { return info }
        var parameters = info.parameters
        parameters["profile-level-id"] = String(level.prefix(4)) + autoLevel
        return RTCVideoCodecInfo(name: info.name, parameters: parameters)
    }

    #if DEBUG
    /// DEV builds: `CMUX_MAC_SCREEN_H264_LEVEL=negotiated` in the host app's
    /// environment opens the encoder at the negotiated level as before (the
    /// 68 fps cap at 3456×2234), to compare both on one build.
    static let usesNegotiatedLevel = ProcessInfo.processInfo.environment["CMUX_MAC_SCREEN_H264_LEVEL"] == "negotiated"
    #endif
}
