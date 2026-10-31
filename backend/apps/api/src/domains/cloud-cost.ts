import type { MachineRow } from "./cloud.ts"

/**
 * What a running Cloud machine costs, for display: the hourly rate of its size and when it last started
 * running. Clients multiply the two for "about $X so far"; neither number is a bill. Both transports run
 * on Freestyle (the direct provider, and the VM API's upstream), so the rate is Freestyle's list price for
 * vCPU and memory (freestyle.sh/docs/vms/pricing-and-limits), the same rates classic `/api/vm` prices
 * its machines from (web/services/vms/machineCost.ts): a 4 vCPU / 8 GB machine is about $0.26 an hour.
 * The rate lives here so a price change reaches every client without a release.
 */
const FREESTYLE_VCPU_HOUR_USD = 0.04032
const FREESTYLE_GIB_HOUR_USD = 0.0129

/** Rate to four decimals of a dollar: enough for "$0.26/h", stable in JSON. */
const roundRate = (usd: number) => Math.round(usd * 10_000) / 10_000

/** The hourly rate of a machine of this size, or null when the size lacks vCPU or memory. */
export const hourlyRateUsd = (size: MachineRow["size"] | undefined): number | null => {
  const cpu = size?.cpu
  const memory = size?.memory_mb
  if (!cpu || !memory || cpu <= 0 || memory <= 0) return null
  return roundRate(cpu * FREESTYLE_VCPU_HOUR_USD + (memory / 1024) * FREESTYLE_GIB_HOUR_USD)
}

/**
 * The cost fields of one public machine. `running_since` is when the machine last became running (a bind,
 * or a start the provider confirmed), null while it is not running: a paused machine costs no compute, and
 * the app shows only its rate "when running". A row from before `running_at` uses its last power time.
 */
export const machineCost = (row: MachineRow): { hourly_rate_usd: number | null; running_since: number | null } => ({
  hourly_rate_usd: hourlyRateUsd(row.size),
  running_since: row.status === "running" ? (row.running_at ?? row.last_power_at ?? null) : null
})
