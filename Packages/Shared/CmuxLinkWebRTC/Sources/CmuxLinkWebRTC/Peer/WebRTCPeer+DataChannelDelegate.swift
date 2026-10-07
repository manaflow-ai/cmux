import Foundation
@preconcurrency import WebRTC

extension WebRTCPeer: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        channelStateChanged(dataChannel)
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        received(buffer.data, on: dataChannel)
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        bufferedAmountChanged(dataChannel, amount: amount)
    }
}
