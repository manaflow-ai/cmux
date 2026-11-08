/// Fixed-capacity storage pool for host-owned framebuffer copies.
actor SimulatorFrameBufferPool {
    private let maximumBufferCount: Int
    private var byteCount: Int?
    private var available: [SimulatorReusableFrameBuffer] = []
    private(set) var allocatedBufferCount = 0

    init(maximumBufferCount: Int) {
        self.maximumBufferCount = max(1, maximumBufferCount)
    }

    func acquire(byteCount: Int) -> SimulatorReusableFrameBuffer? {
        guard byteCount >= 0 else { return nil }
        if let expected = self.byteCount {
            guard expected == byteCount else { return nil }
        } else {
            self.byteCount = byteCount
        }
        if let buffer = available.popLast() { return buffer }
        guard allocatedBufferCount < maximumBufferCount,
              let buffer = SimulatorReusableFrameBuffer(capacity: byteCount) else { return nil }
        allocatedBufferCount += 1
        return buffer
    }

    func recycle(_ buffer: SimulatorReusableFrameBuffer) {
        guard buffer.capacity == byteCount else { return }
        available.append(buffer)
    }
}
