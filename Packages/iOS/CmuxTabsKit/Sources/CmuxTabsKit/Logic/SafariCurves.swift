import Foundation

/// Safari's own motion curves, replayed instead of fitted springs: each is
/// progress (0 -> 1) at 1/60 s steps from the motion's onset, the mean of
/// Safari's per-frame positions on the iOS 26 simulator with the same input
/// (~/nxios-ref/tabs-reaudit-3, tabs-parity-reaudit-3.md). Built by
/// cmux-next `ios-next/scripts/tabs-curves/build-curves.py`; cmux-next `ios-next/scripts/tabs-curves/check.py` compares a
/// recording against them.
struct SafariCurve: Hashable, Sendable {
    let samples: [Double]

    /// Seconds from onset to rest.
    var duration: Double { Double(samples.count - 1) / 60 }

    /// Progress `t` seconds after onset (linear between frames; 1 after the end).
    func value(at t: Double) -> Double {
        guard t > 0 else { return samples.first ?? 0 }
        let x = t * 60
        let i = Int(x)
        guard i + 1 < samples.count else { return samples.last ?? 1 }
        let f = x - Double(i)
        return samples[i] + (samples[i + 1] - samples[i]) * f
    }

    /// The first time the curve reaches `p` (for continuing it from a progress).
    func time(reaching p: Double) -> Double {
        guard p > 0 else { return 0 }
        for i in 1..<samples.count where samples[i] >= p {
            let a = samples[i - 1], b = samples[i]
            let f = b > a ? (p - a) / (b - a) : 0
            return (Double(i - 1) + max(0, min(1, f))) / 60
        }
        return duration
    }

    /// Card to page (a card tapped, Done): Safari, 3 runs (cmux-next tabs-parity-reaudit-3 1a).
    static let zoomIn = SafariCurve(samples: [
        0.0, 0.0379, 0.1367, 0.2182, 0.3387, 0.4365, 0.5282, 0.6097, 0.6806, 0.7336,
        0.7844, 0.8267, 0.8592, 0.8872, 0.9086, 0.9266, 0.9424, 0.9555, 0.9643, 0.9693,
        0.975, 0.9808, 0.9855, 0.9892, 0.9899, 0.9929, 0.9942, 0.9951, 0.9962, 0.9969,
        0.9964, 0.996, 0.998, 1.0, 1.0,
    ])
    /// Page to card (the tabs button): Safari, 2 runs (1c).
    static let zoomOut = SafariCurve(samples: [
        0.0, 0.0339, 0.1235, 0.2291, 0.3431, 0.495, 0.5992, 0.686, 0.7397, 0.8077,
        0.848, 0.8995, 0.9261, 0.9444, 0.9666, 0.9783, 0.991, 1.0, 1.0, 1.0031,
        1.0055, 1.0062, 1.0044, 1.0031, 1.0031, 1.0031, 1.0031, 1.0031, 1.0031, 1.0031,
        1.0031, 1.0031, 1.0031, 1.0026, 1.0, 1.0,
    ])
    /// Cards moving to new slots after a close: Safari, 3 runs re-measured on one simulator (D8).
    static let reflow = SafariCurve(samples: [
        0.0, 0.0496, 0.0653, 0.1182, 0.1996, 0.2918, 0.3846, 0.4746, 0.6121, 0.69,
        0.7115, 0.7605, 0.809, 0.8544, 0.8868, 0.9129, 0.9354, 0.954, 0.9673, 0.9783,
        0.9867, 0.992, 0.9964, 0.9989, 1.0024, 1.0036, 1.0036, 1.0036, 1.0036, 1.0036,
        1.0036, 1.0036, 1.0012, 1.0,
    ])
    /// The last two cards reflowing into the lone card: Safari (audit 3l).
    static let twoToOne = SafariCurve(samples: [
        0.0, 0.0141, 0.0649, 0.1375, 0.2294, 0.3239, 0.4134, 0.5019, 0.5836, 0.6524,
        0.7151, 0.7725, 0.8175, 0.8597, 0.8888, 0.9162, 0.9379, 0.9564, 0.9718, 0.9787,
        0.9881, 0.9945, 0.9995, 1.0, 1.0038, 1.0042, 1.0, 1.0,
    ])
    /// A slowly released card springing back to its slot, from the turnaround: Safari, 3 runs (3g).
    static let snapBack = SafariCurve(samples: [
        0.0, 0.0204, 0.0576, 0.1091, 0.1655, 0.2352, 0.3077, 0.3867, 0.4522, 0.5186,
        0.5813, 0.6359, 0.6875, 0.7322, 0.7728, 0.8072, 0.836, 0.8626, 0.8864, 0.9046,
        0.9208, 0.9335, 0.9462, 0.9546, 0.9635, 0.969, 0.9754, 0.9807, 0.9817, 0.9872,
        0.9876, 0.9916, 0.9938, 0.9938, 0.9938, 0.9938, 0.9938, 0.9964, 1.0, 1.0,
    ])
    /// A card released after a right drag springing back to its slot, from the turnaround: Safari, 3 runs (cmux-next re-audit 3 3i).
    static let snapBackRight = SafariCurve(samples: [
        0.0, 0.0137, 0.033, 0.0686, 0.1279, 0.1828, 0.244, 0.3175, 0.3899, 0.4595,
        0.5208, 0.5763, 0.6328, 0.6903, 0.7326, 0.7715, 0.8083, 0.8389, 0.8647, 0.885,
        0.9023, 0.9217, 0.9415, 0.9435, 0.9593, 0.9605, 0.9783, 0.9802, 0.9802, 0.9802,
        0.9802, 0.9974, 1.0, 1.0,
    ])
    /// The fresh page after the last tab closed, from the lone card's slot: Safari, 2 runs (D2).
    static let lastTab = SafariCurve(samples: [
        0.0, 0.0345, 0.1288, 0.1968, 0.3057, 0.4051, 0.5059, 0.5842, 0.6575, 0.7234,
        0.7732, 0.8205, 0.8558, 0.8841, 0.9075, 0.9261, 0.9451, 0.9503, 0.9592, 0.9685,
        0.9761, 0.9808, 0.9812, 0.9881, 0.9897, 0.9897, 0.9897, 0.9897, 0.9897, 0.9902,
        0.998, 1.0, 1.0,
    ])
    /// Swipe up on the bar (250 pt in 0.25 s) to the grid: Safari, 3 runs, same input (D7).
    static let swipeUp = SafariCurve(samples: [
        0.0, 0.1213, 0.2483, 0.3012, 0.4006, 0.4336, 0.5101, 0.5754, 0.5946, 0.6296,
        0.6601, 0.6841, 0.7014, 0.7198, 0.7436, 0.768, 0.7963, 0.8255, 0.8637, 0.8745,
        0.8949, 0.9119, 0.9299, 0.9465, 0.9587, 0.9684, 0.9769, 0.984, 0.9896, 0.9949,
        0.9984, 1.0007, 1.0026, 1.0044, 1.0054, 1.0061, 1.0058, 1.0053, 1.0049, 1.0047,
        1.0045, 1.0042, 1.0046, 1.0045, 1.0034, 1.0023, 1.002, 1.0015, 1.0013, 1.0,
    ])
    /// A flung card from the finger's end until it is off screen (x1 300 -> 0 pt): Safari, re-measured (D1); it holds 2 frames, then accelerates and slows to the edge.
    static let fling = SafariCurve(samples: [
        0.0, 0.0, 0.0, 0.0177, 0.031, 0.051, 0.08, 0.1177, 0.1667, 0.2243,
        0.289, 0.3557, 0.4243, 0.491, 0.5557, 0.6157, 0.6733, 0.7243, 0.771, 0.811,
        0.849, 0.88, 0.9067, 0.931, 0.9533, 0.969, 0.9843, 1.0,
    ])
}
