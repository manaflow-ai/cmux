import type { Store } from "./store-types.ts"

/** The part of a mysql2/promise connection the store uses. */
export interface MysqlConn {
  query(sql: string, values?: Array<unknown>): Promise<[unknown, unknown]>
  end(): Promise<void>
}

/** cmux-mobile-api's store on PlanetScale MySQL cmux-next-vitess (not implemented yet). */
export const mysqlStore = async (_conn: MysqlConn): Promise<Store> => {
  throw new Error("mysqlStore: not implemented")
}
