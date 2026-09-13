plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "dev.cmux.android.core.ghosttyvt"
    compileSdk = 34
    ndkVersion = "27.2.12479018"

    defaultConfig {
        minSdk = 26

        ndk {
            // Real devices (arm64-v8a) and the typical Android Studio emulator
            // image (x86_64). 32-bit ABIs are intentionally not built — see
            // android/scripts/build-ghostty-vt.sh.
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation(libs.serialization.json)

    testImplementation(libs.junit5.api)
    testImplementation(libs.junit5.params)
    testRuntimeOnly(libs.junit5.engine)
}

tasks.withType<Test> {
    useJUnitPlatform()
}
