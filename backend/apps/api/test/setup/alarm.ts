import { runInDurableObject } from "cloudflare:test"

type AlarmInstance = { alarm?: () => Promise<void>; alarmIdle?: Promise<void> }
const runIn = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: AlarmInstance, state: DurableObjectState) => Promise<T>) => Promise<T>

/**
 * Runs the object's alarm now, always. Use it instead of runDurableObjectAlarm: miniflare also
 * fires real alarms, and runDurableObjectAlarm does nothing (returns false) when the runtime
 * already ran or is running the alarm. The scheduled alarm is deleted first, and OwnerDO queues
 * alarm runs (AlarmSerial), so this run starts after any runtime run in flight. Returns false only
 * for an object with no alarm handler.
 */
export async function fireAlarm(stub: unknown): Promise<boolean> {
  return runIn(stub, async (instance, state) => {
    if (typeof instance.alarm !== "function") return false
    await state.storage.deleteAlarm()
    await instance.alarm()
    return true
  })
}

/**
 * Inside runInDurableObject, before direct calls that use a fake clock: deletes the scheduled
 * alarm and waits for a runtime alarm run in flight, so no real-clock run interleaves with them.
 * Commits inside the callback can schedule a new alarm; call it again after such a commit.
 */
export async function quiesce(instance: AlarmInstance, state: DurableObjectState): Promise<void> {
  await state.storage.deleteAlarm()
  await instance.alarmIdle
}
