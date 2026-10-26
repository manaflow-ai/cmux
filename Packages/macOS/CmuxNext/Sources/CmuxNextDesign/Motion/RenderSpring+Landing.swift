import QuartzCore

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
        /// The call's place in call order, which orders the completions one call supersedes.
        let serial: Int
        private static var lastSerial = 0

        init(_ completion: Completion?) {
            self.completion = completion
            Self.lastSerial &+= 1
            serial = Self.lastSerial
        }

        /// Opens the span `name` (a retarget of an open span keeps it) and closes it at the landing.
        func trace(_ name: String, id: ObjectIdentifier) {
            MotionTrace.begin(name, id: id)
            traces.append((name: name, id: id))
        }

        /// This landing also settles only after `earlier` does, whose springs still add to the
        /// presented value of a key path this one animates.
        func wait(for earlier: Landing) {
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

        /// The newest landing of each key path on one layer, kept on the layer like its spring serial.
        final class Table: NSObject {
            private static let key = "cmux.renderSpring.landings"
            private var newest: [String: Landing] = [:]

            /// The table of `layer`, made on first use.
            static func on(_ layer: CALayer) -> Table {
                if let table = layer.value(forKey: key) as? Table { return table }
                let table = Table()
                layer.setValue(table, forKey: key)
                return table
            }

            /// `landing` takes over `keyPath` and returns the unsettled landings of related key
            /// paths (``RenderSpring/related(_:_:)``), which it supersedes. When `waits` (the key
            /// path animates), `landing` also waits until they settle. Runs no completion, so the
            /// caller supersedes after every key path of the call is taken.
            func take(_ keyPath: String, for landing: Landing, waits: Bool) -> [Landing] {
                var taken: [Landing] = []
                for (path, earlier) in newest {
                    if earlier.settled {
                        newest[path] = nil
                        continue
                    }
                    guard earlier !== landing, RenderSpring.related(path, keyPath) else { continue }
                    taken.append(earlier)
                    if waits { landing.wait(for: earlier) }
                }
                newest[keyPath] = waits ? landing : nil
                return taken
            }
        }
    }
}
