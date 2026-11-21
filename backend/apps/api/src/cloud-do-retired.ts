import { DurableObject } from "cloudflare:workers"

/**
 * The retired local CloudDO namespace (migration v11). NEXT Cloud's CloudDO is cmux-platform's: CLOUD_DO names it
 * by script_name in every deployed env (src/platform-cloud.ts). This class only keeps the old namespace and its
 * pre-cutover rows without a `deleted_classes` migration, which would erase them. Nothing routes here; any call
 * answers 410.
 */
export class CloudDO extends DurableObject {
  override async fetch(): Promise<Response> {
    return new Response("CloudDO moved to cmux-platform", { status: 410 })
  }
}
