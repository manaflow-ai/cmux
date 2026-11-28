/**
 * Runs alarm bodies one at a time. The runtime never overlaps a Durable Object's alarms, so in
 * production this changes nothing. A test that calls alarm() directly while a runtime alarm is
 * awaiting I/O would overlap two runs; the queue makes the second wait, as the runtime would.
 */
export class AlarmSerial {
  private tail: Promise<void> = Promise.resolve()

  run(body: () => Promise<void>): Promise<void> {
    const run = this.tail.then(body)
    this.tail = run.catch(() => {})
    return run
  }

  /** Resolves when no queued alarm body is in flight (test hook). */
  get idle(): Promise<void> {
    return this.tail
  }
}
