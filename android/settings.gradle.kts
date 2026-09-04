pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "cmux-android"

include(":app")
include(":core:transport")
include(":core:rpc")
include(":core:auth")
include(":core:pairing")
include(":feature:auth")
include(":feature:pairing")
include(":feature:workspace")
include(":feature:terminal")
include(":feature:browser")
include(":termux-terminal-emulator")
