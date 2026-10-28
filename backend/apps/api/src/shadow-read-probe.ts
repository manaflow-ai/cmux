/** Shadow-read probe for the compare cron (not implemented yet). */
export const shadowReadProbe = async (
  _env: { readonly PROJECTION_READS?: string | undefined },
  _listUsers: (after: string | null, limit: number) => Promise<ReadonlyArray<string>>,
  _options: { readonly maxPages?: number; readonly pageSize?: number } = {}
): Promise<{ ran: boolean; pages: number; users: number }> => ({ ran: false, pages: 0, users: 0 })
