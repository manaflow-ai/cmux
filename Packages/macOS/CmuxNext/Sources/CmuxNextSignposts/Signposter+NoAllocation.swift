import CmuxNextCompat
import CmuxNextSignpostsC
import CmuxNextTrace

// The signposts that run per key, per key hop and per scheduled main task, with no heap allocation: they emit
// through os_signpost's C macros (CmuxNextSignpostsC), which format typed fields into a stack buffer the compiler
// sizes, as Chromium's TRACE_EVENT macros write typed arguments (base/trace_event/trace_event.h). Their intervals
// are plain values (``KeyFrameInterval``, ``MainTaskInterval``) where `OSSignposter.beginInterval` returns a heap
// `OSSignpostIntervalState`, and the os overlay copies a small Swift `String` argument to the heap. Each also
// writes its trace ring record under its category flag, as every ``Signposter`` emit does (p09-observability 006).
extension Signposter {
    /// Begins the log system's interval and the ring's slice for one scheduled main-thread task
    /// (``SignpostName/stallMainTask``), with its class and owner (`class=<class> owner=<owner>`). The scheduler
    /// opens one per task, so it makes no heap allocation: os_signpost's C macros format the fields into a stack
    /// buffer (CmuxNextSignpostsC) and the interval is a plain value. ``begin(_:taskClass:owner:classID:ownerID:)``
    /// adds their ids to the ring record.
    ///
    /// - Parameters:
    ///   - name: ``SignpostName/stallMainTask``.
    ///   - taskClass: The task's priority class name (`visible`, `automation`, ...).
    ///   - owner: The batch owner or control method that scheduled the task.
    /// - Returns: The interval to end, on this thread, with the ``MainTaskInterval`` overload of `end(_:_:)`.
    public func begin(_ name: SignpostName, taskClass: String, owner: String) -> MainTaskInterval {
        beginTask(name, taskClass: taskClass, owner: owner, arg0: Self.taskArg0(classCode: 0, ownerID: 0))
    }

    /// ``begin(_:taskClass:owner:)`` with the class and owner ids in the ring record: `arg0` holds `ownerID` in
    /// bits 0-31 and the class's code (its position + 1; 0 is the overload without numbers) in bits 32-39.
    ///
    /// - Parameters:
    ///   - name: ``SignpostName/stallMainTask``.
    ///   - taskClass: The task's priority class name (`visible`, `automation`, ...).
    ///   - owner: The batch owner or control method that scheduled the task.
    ///   - classID: The class's position (`MainWorkClass.rawValue`).
    ///   - ownerID: The owner's id interned on the task board (`MainTaskOwner.index`; 0 is the board's "no task").
    /// - Returns: The interval to end, on this thread, with the ``MainTaskInterval`` overload of `end(_:_:)`.
    public func begin(_ name: SignpostName, taskClass: String, owner: String, classID: UInt8,
                      ownerID: UInt32) -> MainTaskInterval {
        beginTask(name, taskClass: taskClass, owner: owner,
                  arg0: Self.taskArg0(classCode: Self.code(position: classID), ownerID: ownerID))
    }

    private func beginTask(_ name: SignpostName, taskClass: String, owner: String, arg0: UInt64) -> MainTaskInterval {
        assert(name == .stallMainTask && category == .stall, "\(name) is not stall.main_task on the stall category")
        let id = cmux_signpost_stall_task_id()
        let beginNanos = clock.nowNanos()
        // A native or small String hands over its NUL-terminated bytes in place, with no heap copy.
        taskClass.withCString { taskClass in
            owner.withCString { owner in cmux_signpost_stall_task_begin(id, taskClass, owner) }
        }
        return MainTaskInterval(id: id, beginUptimeNanos: beginNanos,
                                ring: traceBegin(name, id: OSSignpostID(id), beginNanos: beginNanos, arg0: arg0))
    }

    /// Ends a ``SignpostName/stallMainTask`` interval on the thread that began it.
    public func end(_ name: SignpostName, _ interval: MainTaskInterval) {
        assert(name == .stallMainTask && category == .stall, "\(name) is not stall.main_task on the stall category")
        cmux_signpost_stall_task_end(interval.id)
        closeRing(name, interval.ring, arg0: EndCode.ended)
    }

    /// Begins a ``SignpostName/keyToFrame`` interval for a key-down with no heap allocation: os_signpost's C
    /// macros format `target=<view|terminal> age_ms=<age, 2 decimals>` into a stack buffer (CmuxNextSignpostsC),
    /// where `OSSignposter.beginInterval` returns a heap `OSSignpostIntervalState` per key. The ring record is an
    /// async slice (AB) keyed by the signpost id: `arg0` holds the target's code (1 view, 2 terminal) in bits 0-7
    /// and the age in the top 24 bits. Callers begin one only while ``isEnabled``, which is false while the
    /// keystroke-timing gate is closed (``KeyFrameSignpost/begin(target:eventTimestamp:now:)``).
    ///
    /// - Parameters:
    ///   - name: ``SignpostName/keyToFrame``.
    ///   - target: What has the keyboard.
    ///   - ageMicros: The key's age when its dispatch began, in microseconds, or -1 without a timestamp.
    /// - Returns: The interval to end with the ``KeyFrameInterval`` overload of `end(_:_:_:)`.
    public func begin(_ name: SignpostName, target: KeyFrameSignpost.Target, ageMicros: Int64) -> KeyFrameInterval {
        assert(name == .keyToFrame && category == .key, "\(name) is not key.frame on the key category")
        let id = cmux_signpost_key_frame_id()
        let beginNanos = clock.nowNanos()
        let ageMilliseconds = ageMicros < 0 ? -1 : Double(ageMicros) / 1_000
        cmux_signpost_key_frame_begin(id, target == .terminal ? 1 : 0, ageMilliseconds)
        let ring = traceBegin(name, id: OSSignpostID(id), beginNanos: beginNanos,
                              arg0: target.traceCode | Self.inputAgeBits(milliseconds: ageMilliseconds))
        return KeyFrameInterval(id: id, metricKitID: mirror.begin(name), beginUptimeNanos: beginNanos, ring: ring)
    }

    /// Ends a ``SignpostName/keyToFrame`` interval that its commit boundary closed, as the ``SignpostInterval``
    /// overload does: a missed end carries `commit=missed` and is not mirrored to MetricKit. The ring's AE has the
    /// begin's id and the end's code (`EndCode`) in `arg0`.
    public func end(_ name: SignpostName, _ interval: KeyFrameInterval, _ outcome: CommitBoundary.Outcome) {
        assert(name == .keyToFrame && category == .key, "\(name) is not key.frame on the key category")
        switch outcome {
        case .committed:
            cmux_signpost_key_frame_end(interval.id, 0)
            if let id = interval.metricKitID { mirror.end(name, id: id) }
        case .missed:
            cmux_signpost_key_frame_end(interval.id, 1)
        }
        closeRing(name, interval.ring, arg0: EndCode.of(outcome))
    }

    /// Records a ``SignpostName/stallOverBudget`` point event for a task that ran past its class's budget, with no
    /// heap allocation: os_signpost's C macros format `class=<class> owner=<owner> ms=<task time, 2 decimals>
    /// budget_ms=<the class's budget, 2 decimals>` into a stack buffer (CmuxNextSignpostsC), so the caller builds
    /// no `String`. The ring record's `arg0` holds `ownerID` in bits 0-31, the class's code (its position + 1) in
    /// bits 32-39 and the budget in microseconds in the top 24 (saturated, as an input age); `arg1` holds the task's
    /// own time in nanoseconds.
    ///
    /// - Parameters:
    ///   - name: ``SignpostName/stallOverBudget``.
    ///   - taskClass: The task's priority class name (`visible`, `automation`, ...).
    ///   - owner: The batch owner or control method that scheduled the task.
    ///   - classID: The class's position (`MainWorkClass.rawValue`).
    ///   - ownerID: The owner's id interned on the task board (`MainTaskOwner.index`).
    ///   - ownNanos: The task's own time (its nested tasks' time taken out).
    ///   - budgetNanos: Its class's per-frame budget.
    public func event(_ name: SignpostName, taskClass: String, owner: String, classID: UInt8, ownerID: UInt32,
                      ownNanos: UInt64, budgetNanos: UInt64) {
        assert(name == .stallOverBudget && category == .stall, "\(name) is not stall.over_budget on the stall category")
        let milliseconds = Double(ownNanos) / 1_000_000
        let budgetMilliseconds = Double(budgetNanos) / 1_000_000
        taskClass.withCString { taskClass in
            owner.withCString { owner in cmux_signpost_stall_over_budget(taskClass, owner, milliseconds, budgetMilliseconds) }
        }
        let arg0 = Self.taskArg0(classCode: Self.code(position: classID), ownerID: ownerID)
            | Self.inputAgeBits(milliseconds: budgetMilliseconds)
        trace.event(name, arg0: arg0, arg1: ownNanos)
    }

    /// Records one hop of a key press's flow (``SignpostName/keyFlow``), formatted by the log system
    /// only when something reads it (`hop=<hop> flow=<id> age_us=<age>`). os_signpost's C macros format it into a
    /// stack buffer (CmuxNextSignpostsC) with the hop's static name, so a hop makes no heap allocation. The ring
    /// record is a flow record with the flow id in `arg1`: a flow out (`s`) at the press's first hop, a flow in
    /// (`f`) at every later one, so an exporter draws the press's arrows and joins them to the daemon's and host's
    /// flow records. `arg0` holds the hop's ``KeyFlowHop/traceCode`` in bits 0-7 and the age in bits 8-63 (two's
    /// complement: an arithmetic shift right by 8 reads -1 back). Nothing, in the log or the ring, while the
    /// keystroke-timing gate is closed (``TraceRuntime/isKeyTimingSuppressed``, task 128).
    ///
    /// - Parameters:
    ///   - hop: The hop.
    ///   - flow: The key press's flow id.
    ///   - ageMicroseconds: The key event's age at this hop, or -1.
    public func flowHop(_ hop: KeyFlowHop, flow: UInt64, ageMicroseconds: Int64 = -1) {
        assert(SignpostName.keyFlow.category == category, "key.flow is not in category \(category)")
        guard !trace.isKeyTimingSuppressed else { return }
        let hopName = hop.staticName
        hopName.utf8Start.withMemoryRebound(to: CChar.self, capacity: hopName.utf8CodeUnitCount + 1) {
            cmux_signpost_key_flow_hop($0, flow, ageMicroseconds)
        }
        let arg0 = UInt64(hop.traceCode) | UInt64(bitPattern: ageMicroseconds) << 8
        if hop.startsFlow {
            trace.flowOut(.keyFlow, flow: flow, arg0: arg0)
        } else {
            trace.flowIn(.keyFlow, flow: flow, arg0: arg0)
        }
    }
}
