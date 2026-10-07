import CmuxLinkSignaling
import Foundation
@preconcurrency import WebRTC

extension WebRTCPeer: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        emit(.negotiationNeeded)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        emit(.iceState(newState))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { emit(.gatheringComplete) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        emit(.candidate(ICECandidateInit(
            candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: Int(candidate.sdpMLineIndex)
        )))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        registerRemote(dataChannel)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChangeLocalCandidate local: RTCIceCandidate,
        remoteCandidate remote: RTCIceCandidate,
        lastReceivedMs lastDataReceivedMs: Int32,
        changeReason reason: String
    ) {
        emit(.selectedPair(local: local.sdp, remote: remote.sdp))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track { emit(.remoteTrack(RemoteTrackBox(track: track))) }
    }
}
