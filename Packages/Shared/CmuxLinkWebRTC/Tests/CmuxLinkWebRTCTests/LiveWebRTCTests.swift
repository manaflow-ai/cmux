import Testing

/// Every suite that runs real libwebrtc peers, run one test at a time: the
/// peers of parallel tests share CPU and libwebrtc threads on a loaded Mac,
/// which turns latency bounds into load measurements.
@Suite("Live WebRTC", .serialized)
struct LiveWebRTCTests {}
