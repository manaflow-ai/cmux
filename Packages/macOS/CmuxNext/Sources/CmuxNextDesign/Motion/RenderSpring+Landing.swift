import QuartzCore
import ObjectiveC

extension RenderSpring {
    /// When one ``RenderSpring`` call lands. Chrome's model: an implicit animation observer
    /// hears once that its animations completed, or that a newer animation of the same
    /// property aborted them (ui/compositor/layer_animation_observer.h,
    /// `ImplicitAnimationObserver::OnImplicitAnimationsCompleted` and
    /// `WasAnimationAbortedForProperty`).
    ///
    /// Additive springs never replace each other: a retarget's springs run on top of the
    /// earlier ones, and the presented value rests only when all of them end. So a landing
    /// settles when its own springs end and every earlier landing it took a key path from has
    /// settled; the earlier landing's completion already ran, not finished, when it was taken over.
    final class Landing {
        private var completion: Completion?
        /// Its own springs (1 until its transaction completes) plus the earlier landings not settled.
        private var pending = 1
        private var springsEnded = false
        private var waitsOn: Set<ObjectIdentifier> = []
        /// Later landings that wait until this one settles.
        private var dependents: [Landing] = []
        /// The `debug.motion` spans this landing closes when it settles.
        private var traces: [(name: String, id: ObjectIdentifier)] = []
        /// Every spring this landing waits for has ended.
        private(set) var settled = false

        init(_ completion: Completion?) {
            self.completion = completion
        }

        /// Opens the span `name` (a retarget of an open span keeps it) and closes it at the landing.
        func trace(_ name: String, id: ObjectIdentifier) {
            MotionTrace.begin(name, id: id)
            traces.append((name: name, id: id))
        }

        /// This landing also settles only after `earlier` does, whose springs still add to the
        /// presented value of a key path this one animates.
        func settles(after earlier: Landing) {
            guard earlier !== self, !earlier.settled, waitsOn.insert(ObjectIdentifier(earlier)).inserted else { return }
            pending += 1
            earlier.dependents.append(self)
        }

        /// A newer call took over one of its key paths: the completion runs now, not finished,
        /// and the newer landing closes this one's spans when it settles.
        func supersede(by newer: Landing) {
            newer.traces += traces
            traces = []
            finish(false)
        }

        /// The springs this call added have ended or were removed (its transaction's completion),
        /// or the call added none.
        func springsDidEnd() {
            guard !springsEnded else { return }
            springsEnded = true
            release()
        }

        private func release() {
            pending -= 1
            guard pending == 0 else { return }
            settled = true
            for trace in traces { MotionTrace.end(trace.name, id: trace.id) }
            traces = []
            finish(true)
            let later = dependents
            dependents = []
            for landing in later { landing.release() }
        }

        private func finish(_ finished: Bool) {
            guard let done = completion else { return }
            completion = nil
            done(finished)
        }

        /// The newest landing of each key path on one layer, oldest call first, and the layer's
        /// spring serial, kept on the layer as an associated object (it lives as long as the layer).
        /// Calls on one value meet only on its layer, so this is the call order the completions keep.
        final class Table {
            /// The associated-object key: one byte allocated once, never freed.
            private static let key = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
            private var newest: [(keyPath: String, landing: Landing)] = []
            private var serial = 0

            /// The table of `layer`, made on first use.
            static func on(_ layer: CALayer) -> Table {
                if let table = objc_getAssociatedObject(layer, key) as? Table { return table }
                let table = Table()
                objc_setAssociatedObject(layer, key, table, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                return table
            }

            /// The next spring serial on the layer (``RenderSpring`` animation keys).
            func nextSerial() -> Int {
                serial &+= 1
                return serial
            }

            /// `landing` takes over `keyPath` and returns the unsettled landings of related key
            /// paths (``RenderSpring/related(_:_:)``), oldest first, which it supersedes. When
            /// `waits` (the key path animates), `landing` also settles only after they do. Runs no
            /// completion, so the caller supersedes after every key path of the call is taken.
            func take(_ keyPath: String, for landing: Landing, waits: Bool) -> [Landing] {
                newest.removeAll { $0.landing.settled }
                var taken: [Landing] = []
                for (path, earlier) in newest where earlier !== landing && RenderSpring.related(path, keyPath) {
                    guard !taken.contains(where: { $0 === earlier }) else { continue }
                    taken.append(earlier)
                    if waits { landing.settles(after: earlier) }
                }
                newest.removeAll { $0.keyPath == keyPath }
                if waits { newest.append((keyPath: keyPath, landing: landing)) }
                return taken
            }
        }
    }
}
