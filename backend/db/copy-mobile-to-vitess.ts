/** Copy cmux-mobile-api's Postgres tables into cmux-next-vitess `mobile_*` (not implemented yet). */
import type mysql from "mysql2/promise"
export interface PgLike {
  query(sql: string): Promise<{ rows: Array<Record<string, unknown>> }>
}
export const copyMobile = async (_pg: PgLike, _my: Pick<mysql.Connection, "query">): Promise<Record<string, number>> => {
  throw new Error("copyMobile: not implemented")
}
export const verifyMobile = async (_pg: PgLike, _my: Pick<mysql.Connection, "query">): Promise<Array<{ table: string; equal: boolean; pgCount: number; mysqlCount: number; changed: Array<string> }>> => {
  throw new Error("verifyMobile: not implemented")
}
