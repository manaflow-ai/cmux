/**
 * One mysql2 connection to PlanetScale MySQL through a Hyperdrive binding (or a plain
 * {host, port, user, password, database} object in tests). Loaded lazily by callers, so mysql2
 * stays off the request path. The session runs in UTC: datetime(3) columns hold UTC.
 */
export interface MysqlTarget {
  readonly host: string
  readonly port: number
  readonly user: string
  readonly password: string
  readonly database: string
  /** A direct PlanetScale connection (tests, operator jobs) needs TLS; a Hyperdrive binding never sets this. */
  readonly tls?: boolean
}

export interface MysqlClient {
  query(sql: string, values?: Array<unknown>): Promise<unknown>
  end(): Promise<void>
}

export const connectMysql = async (target: MysqlTarget, options: { readonly timeoutMs?: number } = {}): Promise<MysqlClient> => {
  const { createConnection } = await import("mysql2/promise")
  const conn = await createConnection({
    host: target.host,
    port: target.port,
    user: target.user,
    password: target.password,
    database: target.database,
    // Workers forbid eval; Hyperdrive terminates TLS to PlanetScale itself.
    disableEval: true,
    ...(target.tls ? { ssl: { rejectUnauthorized: true } } : {}),
    timezone: "Z",
    dateStrings: true,
    connectTimeout: options.timeoutMs ?? 10_000
  })
  await conn.query("SET time_zone = '+00:00'")
  return {
    query: (sql, values) => conn.query(sql, values),
    end: () => conn.end()
  }
}
