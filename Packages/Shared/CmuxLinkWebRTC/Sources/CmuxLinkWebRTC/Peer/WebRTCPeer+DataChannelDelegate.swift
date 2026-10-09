import Foundation
@preconcurrency import WebRTC

/// libwebrtc calls these on its own C++ threads, which have no autorelease
/// pool that ever drains: every autoreleased object (the `NSData` behind
/// `buffer.data`) would live until the thread exits, so a long transfer
/// held every received byte (D2's raw run). Each callback drains its own pool.
extension WebRTCPeer: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        autoreleasepool { channelStateChanged(dataChannel) }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        autoreleasepool { received(buffer.data, on: dataChannel) }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        autoreleasepool { bufferedAmountChanged(dataChannel, amount: amount) }
    }
}
