struct DeterministicUnicodeGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextPrintableString() -> String {
        let length = Int(next() % 16) + 1
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(length)

        while scalars.count < length {
            let value = UInt32(next() % 0x11_0000)
            guard value >= 0x20, let scalar = Unicode.Scalar(value) else {
                continue
            }
            scalars.append(scalar)
        }

        return String(scalars)
    }

    private mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
