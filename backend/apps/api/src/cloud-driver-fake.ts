import type { SqlStore } from "@cmux/ownership"
import { DriverError } from "./team-vm-driver.ts"
import { createBody, LIST_PAGE, type CreateOptions, type ListedVm, type RawCloudDriver, type VmResources, type VmTag } from "./cloud-driver.ts"

/**
 * Test provider (ENVIRONMENT=test, CLOUD_DRIVER=fake): VMs in the object's own SQLite.
 * `fail_next` makes the next calls fail as retryable (a cut-off call).
 */
export class FakeCloudDriver implements RawCloudDriver {
  constructor(private readonly sql: SqlStore) {
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_fake_vm (name TEXT PRIMARY KEY, id TEXT NOT NULL UNIQUE, tag TEXT NOT NULL, idle INTEGER, state TEXT NOT NULL DEFAULT 'running', cpu INTEGER NOT NULL DEFAULT 2, memory INTEGER NOT NULL DEFAULT 4096, storage INTEGER NOT NULL DEFAULT 16384)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_fake_ctl (id INTEGER PRIMARY KEY CHECK (id = 1), fail_next INTEGER NOT NULL DEFAULT 0, creates INTEGER NOT NULL DEFAULT 0, deletes INTEGER NOT NULL DEFAULT 0, fail_list INTEGER NOT NULL DEFAULT 0, pauses INTEGER NOT NULL DEFAULT 0, starts INTEGER NOT NULL DEFAULT 0, power_then_fail INTEGER NOT NULL DEFAULT 0, resizes INTEGER NOT NULL DEFAULT 0, resize_refuse INTEGER NOT NULL DEFAULT 0, resize_partial INTEGER NOT NULL DEFAULT 0, image_cpu INTEGER NOT NULL DEFAULT 2, image_memory INTEGER NOT NULL DEFAULT 4096, image_storage INTEGER NOT NULL DEFAULT 16384, state_reads INTEGER NOT NULL DEFAULT 0, power_refuse INTEGER NOT NULL DEFAULT 0, power_calls INTEGER NOT NULL DEFAULT 0)`)
    sql.exec(`INSERT OR IGNORE INTO cloud_fake_ctl (id) VALUES (1)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS cloud_fake_file (vm TEXT NOT NULL, path TEXT NOT NULL, content TEXT NOT NULL, mode INTEGER NOT NULL, PRIMARY KEY (vm, path))`)
  }

  private maybeFail() {
    const n = this.sql.exec<{ fail_next: number }>(`SELECT fail_next FROM cloud_fake_ctl WHERE id = 1`)[0]!.fail_next
    if (n > 0) {
      this.sql.exec(`UPDATE cloud_fake_ctl SET fail_next = fail_next - 1 WHERE id = 1`)
      throw new DriverError("cloud.provider.unavailable", "fake provider: no answer", false)
    }
  }

  async find(name: string) {
    this.maybeFail()
    const row = this.sql.exec<{ id: string; tag: string; state: string }>(`SELECT id, tag, state FROM cloud_fake_vm WHERE name = ?`, name)[0]
    this.sql.exec(`UPDATE cloud_fake_ctl SET state_reads = state_reads + 1 WHERE id = 1`)
    // "<none>" stands for an answer without a state field.
    return row ? { id: row.id, tag: JSON.parse(row.tag) as Record<string, unknown>, state: row.state === "<none>" ? null : row.state } : null
  }

  async create(name: string, tag: VmTag, opts: CreateOptions) {
    this.maybeFail()
    const body = createBody(name, "fake", tag, opts)
    // The image decides the size (Freestyle has no size at create); image_size in fakeControl sets it.
    const img = this.sql.exec<{ image_cpu: number; image_memory: number; image_storage: number }>(`SELECT image_cpu, image_memory, image_storage FROM cloud_fake_ctl WHERE id = 1`)[0]!
    this.sql.exec(`INSERT INTO cloud_fake_vm (name, id, tag, idle, cpu, memory, storage) VALUES (?, ?, ?, ?, ?, ?, ?)`, name, `fs-${name}`, JSON.stringify(body.metadata), body.idleTimeoutSeconds, img.image_cpu, img.image_memory, img.image_storage)
    this.sql.exec(`UPDATE cloud_fake_ctl SET creates = creates + 1 WHERE id = 1`)
    return { id: `fs-${name}`, tag: null }
  }

  async writeFile(id: string, path: string, content: string, mode: number) {
    this.maybeFail()
    this.sql.exec(`INSERT INTO cloud_fake_file (vm, path, content, mode) VALUES (?, ?, ?, ?) ON CONFLICT (vm, path) DO UPDATE SET content = excluded.content, mode = excluded.mode`, id, path, content, mode)
  }

  /** Report-only path: never fails on purpose, so a background sweep cannot eat a test's fail_next. */
  async list(filter: string, offset: number) {
    if (this.sql.exec<{ fail_list: number }>(`SELECT fail_list FROM cloud_fake_ctl WHERE id = 1`)[0]!.fail_list) throw new DriverError("cloud.provider.unavailable", "fake provider: list failed", false)
    const [key, value] = [filter.slice(0, filter.indexOf(":")), filter.slice(filter.indexOf(":") + 1)]
    const all = this.sql.exec<{ name: string; id: string; tag: string }>(`SELECT name, id, tag FROM cloud_fake_vm ORDER BY name`)
    const vms = all.map((r) => ({ id: r.id, name: r.name, tag: JSON.parse(r.tag) as Record<string, unknown> })).filter((v) => v.tag[key] === value)
    return { vms: vms.slice(offset, offset + LIST_PAGE), total: vms.length }
  }

  async delete(id: string) {
    this.maybeFail()
    const gone = this.sql.exec<{ name: string }>(`DELETE FROM cloud_fake_vm WHERE id = ? RETURNING name`, id)
    if (gone.length) this.sql.exec(`UPDATE cloud_fake_ctl SET deletes = deletes + 1 WHERE id = 1`)
  }

  async pause(id: string) {
    this.power(id, "paused", "pauses")
  }

  async start(id: string) {
    this.power(id, "running", "starts")
  }

  /** Like Freestyle: 409 when the VM is already in that state; `power_then_fail` changes the VM, then answers 409 (a lost answer, then a retry). */
  private power(id: string, target: string, counter: "pauses" | "starts") {
    this.maybeFail()
    this.sql.exec(`UPDATE cloud_fake_ctl SET power_calls = power_calls + 1 WHERE id = 1`)
    if (Number(this.sql.exec<{ n: number }>(`SELECT power_refuse AS n FROM cloud_fake_ctl WHERE id = 1`)[0]!.n) > 0) {
      this.sql.exec(`UPDATE cloud_fake_ctl SET power_refuse = power_refuse - 1 WHERE id = 1`)
      throw new DriverError("cloud.provider.refused", "fake provider: 400 refused", true)
    }
    const vm = this.sql.exec<{ state: string }>(`SELECT state FROM cloud_fake_vm WHERE id = ?`, id)[0]
    if (!vm) throw new DriverError("cloud.provider.vm_missing", "fake provider: 404", true)
    if (vm.state === target) throw new DriverError("cloud.provider.conflict", "fake provider: 409 already in that state", true)
    this.sql.exec(`UPDATE cloud_fake_vm SET state = ? WHERE id = ?`, target, id)
    this.sql.exec(`UPDATE cloud_fake_ctl SET ${counter} = ${counter} + 1 WHERE id = 1`)
    const lost = Number(this.sql.exec<{ n: number }>(`SELECT power_then_fail AS n FROM cloud_fake_ctl WHERE id = 1`)[0]!.n)
    if (lost > 0) {
      this.sql.exec(`UPDATE cloud_fake_ctl SET power_then_fail = power_then_fail - 1 WHERE id = 1`)
      throw new DriverError("cloud.provider.conflict", "fake provider: 409 already in that state (after a lost answer)", true)
    }
  }

  async state(id: string) {
    const st = this.sql.exec<{ state: string }>(`SELECT state FROM cloud_fake_vm WHERE id = ?`, id)[0]?.state ?? null
    return st === "<none>" ? null : st
  }

  /** Like Freestyle: grow only (400), the disk only on a running VM (409); `resize_refuse` refuses the next call (400, final). */
  async resize(id: string, size: VmResources) {
    this.maybeFail()
    const vm = this.sql.exec<{ state: string; cpu: number; memory: number; storage: number }>(`SELECT state, cpu, memory, storage FROM cloud_fake_vm WHERE id = ?`, id)[0]
    if (!vm) throw new DriverError("cloud.provider.vm_missing", "fake provider: 404", true)
    const refuse = Number(this.sql.exec<{ n: number }>(`SELECT resize_refuse AS n FROM cloud_fake_ctl WHERE id = 1`)[0]!.n)
    if (refuse > 0) {
      this.sql.exec(`UPDATE cloud_fake_ctl SET resize_refuse = resize_refuse - 1 WHERE id = 1`)
      throw new DriverError("cloud.provider.refused", "fake provider: 400 resize refused", true)
    }
    if (size.cpu < vm.cpu || size.memory < vm.memory || size.storage < vm.storage) throw new DriverError("cloud.provider.refused", "fake provider: 400 grow only", true)
    const partial = Number(this.sql.exec<{ n: number }>(`SELECT resize_partial AS n FROM cloud_fake_ctl WHERE id = 1`)[0]!.n)
    if (partial > 0) {
      this.sql.exec(`UPDATE cloud_fake_ctl SET resize_partial = resize_partial - 1 WHERE id = 1`)
      this.sql.exec(`UPDATE cloud_fake_vm SET cpu = ? WHERE id = ?`, size.cpu, id)
      throw new DriverError("cloud.provider.refused", "fake provider: 400 after growing vCPU only", true)
    }
    if (size.storage > vm.storage && vm.state !== "running") throw new DriverError("cloud.provider.conflict", "fake provider: 409 disk grows only on a running VM", true)
    this.sql.exec(`UPDATE cloud_fake_vm SET cpu = ?, memory = ?, storage = ? WHERE id = ?`, size.cpu, size.memory, size.storage, id)
    this.sql.exec(`UPDATE cloud_fake_ctl SET resizes = resizes + 1 WHERE id = 1`)
  }

  async resources(id: string) {
    const vm = this.sql.exec<{ cpu: number; memory: number; storage: number }>(`SELECT cpu, memory, storage FROM cloud_fake_vm WHERE id = ?`, id)[0]
    return vm ? { cpu: Number(vm.cpu), memory: Number(vm.memory), storage: Number(vm.storage) } : null
  }
}
