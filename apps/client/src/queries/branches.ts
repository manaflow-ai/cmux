// Re-export the OpenAPI-generated query options for branches
// These are used in the dashboard and diff pages for lazy-loading branches
export {
  getApiIntegrationsGithubDefaultBranchOptions,
  getApiIntegrationsGithubBranchesOptions,
} from "@cmux/www-openapi-client/react-query";

export { getApiIntegrationsGithubBranches } from "@cmux/www-openapi-client";
